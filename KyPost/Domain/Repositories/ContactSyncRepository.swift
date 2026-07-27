//
//  ContactSyncRepository.swift
//  KyPost
//
//  Contact CRUD + sync against the backend, mirroring the Android reference
//  ContactSyncRepository.kt: pull when no local changes are queued, push
//  otherwise; reconcile server-assigned uids for local creates; handle
//  tooOld by discarding the cursor + cache for a full re-pull.
//

import Foundation

enum ContactSyncError: Error, Equatable {
    /// Contact sync uses relay auth; requires a stored pairing.
    case notPaired
}

struct ContactSyncSummary: Equatable, Sendable {
    var pushed: Int
    var applied: Int
    var newCursor: Int
}

final class ContactSyncRepository {
    private let client: ContactSyncClient
    private let contactDAO: ContactDAO
    private let cursorStore: ContactCursorStore
    private let pendingDeletesStore: ContactPendingDeletesStore
    private let securePairingStore: SecurePairingStore
    /// Mirrors changes into the system Contacts database when enabled; nil in
    /// tests that don't exercise the export.
    private let systemContactsExporter: SystemContactsExporter?
    /// Photo bytes for synced photoRefs; nil in tests that don't exercise it.
    private let photoCache: ContactPhotoCache?
    /// Keys the user verified out of band, remembered across a `tooOld` wipe
    /// so the re-pull can't pass off a substituted key as a first sighting.
    private let verifiedKeyStore: VerifiedPgpKeyStore?

    init(
        client: ContactSyncClient,
        contactDAO: ContactDAO,
        cursorStore: ContactCursorStore,
        pendingDeletesStore: ContactPendingDeletesStore,
        securePairingStore: SecurePairingStore,
        systemContactsExporter: SystemContactsExporter? = nil,
        photoCache: ContactPhotoCache? = nil,
        verifiedKeyStore: VerifiedPgpKeyStore? = nil
    ) {
        self.client = client
        self.contactDAO = contactDAO
        self.cursorStore = cursorStore
        self.pendingDeletesStore = pendingDeletesStore
        self.securePairingStore = securePairingStore
        self.systemContactsExporter = systemContactsExporter
        self.photoCache = photoCache
        self.verifiedKeyStore = verifiedKeyStore
    }

    // MARK: - Local CRUD

    func contacts() async throws -> [Contact] {
        try await contactDAO.listAll()
    }

    /// Saves a local create/edit and marks it for the next sync.
    func saveContact(_ contact: Contact) async throws {
        var dirty = contact
        dirty.needsSync = true
        dirty.updatedAt = Date()
        try await contactDAO.upsert(contacts: [dirty])
        // The user is the authority on their own key: an edit (including a
        // freshly scanned QR key) resets what we remember as verified, and
        // clearing the key here really does clear it.
        if let pgpKey = dirty.pgpKey, !pgpKey.isEmpty {
            verifiedKeyStore?.remember(uid: dirty.uid, key: pgpKey)
        } else {
            verifiedKeyStore?.forget(uid: dirty.uid)
        }
        await systemContactsExporter?.exportUpsert(dirty)
    }

    /// Trusts a PGP key that arrived via sync and was held for review
    /// (`applyPgpKey`), replacing the previously-stored key. Call only after
    /// the user has independently re-verified the new key out-of-band.
    func acceptPendingPgpKey(for contact: Contact) async throws {
        guard let pending = contact.pendingPgpKey else { return }
        var updated = contact
        updated.pgpKey = pending
        updated.pendingPgpKey = nil
        try await contactDAO.upsert(contacts: [updated])
        // The user re-verified and accepted: this is now the trusted key.
        verifiedKeyStore?.remember(uid: updated.uid, key: pending)
    }

    /// Discards a PGP key that arrived via sync, keeping the key already on
    /// file. The server still holds the new key, so it reappears for review
    /// on a later sync until the user accepts it or edits the contact.
    func dismissPendingPgpKey(for contact: Contact) async throws {
        guard contact.pendingPgpKey != nil else { return }
        var updated = contact
        updated.pendingPgpKey = nil
        try await contactDAO.upsert(contacts: [updated])
    }

    /// Deletes locally now; synced contacts get a tombstone so the delete
    /// reaches the server with the next sync request.
    func deleteContact(_ contact: Contact) async throws {
        if let uid = contact.uid {
            try await contactDAO.delete(uid: uid)
            pendingDeletesStore.add(uid)
            verifiedKeyStore?.forget(uid: uid)
        } else {
            // Never reached the server; deleting locally is enough.
            try await contactDAO.deleteLocal(localId: contact.localId)
        }
        await systemContactsExporter?.exportDelete(localId: contact.localId)
    }

    // MARK: - Sync

    /// Serializes syncs. Overlapping calls (manual Sync button, the contacts
    /// change monitor, foreground triggers) would each read the same pending
    /// set and push it twice, duplicating contacts server-side. Each caller
    /// chains its own full pass after the in-flight one. Chaining (instead
    /// of polling the in-flight task in a loop) matters: awaiting an
    /// already-completed task can resume without suspending, so a polling
    /// loop can spin on the main actor and deadlock the app.
    private var inFlightSync: Task<ContactSyncSummary, Error>?

    @discardableResult
    func sync() async throws -> ContactSyncSummary {
        let previous = inFlightSync
        let task = Task { () throws -> ContactSyncSummary in
            _ = try? await previous?.value
            return try await performSync()
        }
        inFlightSync = task
        defer { if inFlightSync == task { inFlightSync = nil } }
        return try await task.value
    }

    private func performSync() async throws -> ContactSyncSummary {
        guard let pairing = try securePairingStore.loadPairing() else {
            throw ContactSyncError.notPaired
        }
        let auth = RelayAuth(pairing: pairing)
        let cursor = cursorStore.lastCursor

        let pending = try await contactDAO.listPendingSync()
        // The server silently drops any non-delete change with an empty fn
        // (llama-labels contacts_handlers.go), so a nameless contact is never
        // echoed back and can never reconcile — pushing it just strands it.
        // Keep it local and pending until it has a name.
        let pushable = pending.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let tombstones = pendingDeletesStore.all()
        let changes = pushable.map(Self.toWireDTO)
            + tombstones.map { ContactDTO(uid: $0, rev: 0, deleted: true) }

        // Pull when nothing is queued, push otherwise (Android sync()).
        let response: ContactSyncPullResponse
        if changes.isEmpty {
            response = try await client.pull(serverUrl: pairing.srv, auth: auth, since: cursor)
        } else {
            response = try await client.push(
                serverUrl: pairing.srv,
                auth: auth,
                baseCursor: cursor,
                changes: changes
            )
        }

        if response.tooOld == true {
            // Cursor predates the server's history window: full re-pull next
            // sync. ponytail: unsynced local edits are wiped here — Android
            // keeps them in a separate change queue that survives the wipe.
            cursorStore.reset()
            pendingDeletesStore.clear()
            try await contactDAO.clearAll()
            return ContactSyncSummary(pushed: changes.count, applied: 0, newCursor: 0)
        }

        let changed = response.changed ?? []
        let deleted = response.deleted ?? []

        // Reconcile before applying so the server's copy of a local create
        // updates the existing row (matched by its new uid) instead of
        // inserting a duplicate.
        let creates = pushable.filter { $0.uid == nil }
        for assignment in ContactSyncReconciliation.reconcile(
            localPending: creates,
            responseChanged: changed
        ) {
            try await contactDAO.assignUid(localId: assignment.localId, uid: assignment.uid)
        }

        var applied = 0
        for dto in changed {
            guard let uid = dto.uid, !uid.isEmpty else { continue }
            try await applyServerContact(uid: uid, dto: dto)
            applied += 1
        }
        for dto in deleted {
            guard let uid = dto.uid, !uid.isEmpty else { continue }
            try await contactDAO.delete(uid: uid)
            applied += 1
        }

        // Edits are confirmed by the push itself; creates are confirmed only
        // by reconciliation (assignUid clears their flag), so an unmatched
        // create keeps needsSync and retries on the next sync.
        try await contactDAO.clearNeedsSync(
            localIds: pushable.filter { $0.uid != nil }.map(\.localId)
        )
        pendingDeletesStore.clear()
        cursorStore.advance(to: response.cursor)

        // Photos before the system-contacts export so freshly-arrived bytes
        // make it onto the cards in the same pass.
        await fetchMissingPhotos(serverUrl: pairing.srv, auth: auth)

        // tooOld returns early above on purpose: links survive the wipe and
        // this reconcile re-links re-pulled contacts by uid instead of
        // deleting and recreating their system cards.
        await systemContactsExporter?.reconcileAll()

        return ContactSyncSummary(
            pushed: changes.count,
            applied: applied,
            newCursor: cursorStore.lastCursor
        )
    }

    // MARK: - Dedupe

    /// Asks the server to merge duplicate contacts (Mobile_Contacts_DEDupe.md).
    /// Single-purpose on purpose: the merges arrive through the normal sync
    /// delta, so the caller runs `sync()` afterwards to pick them up.
    func dedupe() async throws -> ContactDedupeReport {
        guard let pairing = try securePairingStore.loadPairing() else {
            throw ContactSyncError.notPaired
        }
        return try await client.dedupe(
            serverUrl: pairing.srv,
            auth: RelayAuth(pairing: pairing)
        )
    }

    // MARK: - Private

    /// Best-effort byte fetch for photoRefs the cache doesn't have yet. A 401
    /// means the backend hasn't shipped pairing auth for the photo endpoint
    /// (llama-labels Part 0 gap) — stop for this pass instead of 401-ing once
    /// per contact; any other failure skips just that contact.
    private func fetchMissingPhotos(serverUrl: String, auth: RelayAuth) async {
        guard let photoCache else { return }
        let contacts = (try? await contactDAO.listAll()) ?? []
        for contact in contacts {
            guard let uid = contact.uid,
                  let photoRef = contact.photoRef,
                  !photoRef.isEmpty,
                  !photoCache.hasData(for: photoRef)
            else { continue }
            do {
                let data = try await client.fetchPhoto(
                    serverUrl: serverUrl,
                    auth: auth,
                    uid: uid
                )
                photoCache.store(data, for: photoRef)
            } catch NetworkError.unauthorized {
                return
            } catch {
                continue
            }
        }
    }

    /// Creates push with uid "" (Android contract); edits carry uid + rev.
    /// Sends the complete payload — the server replaces the whole contact on
    /// upsert, so an omitted field would be wiped server-side. Arrays are
    /// always present (an emptied list must clear); empty scalars go as nil,
    /// which the server decodes as its zero value.
    private static func toWireDTO(_ contact: Contact) -> ContactDTO {
        ContactDTO(
            uid: contact.uid ?? "",
            rev: contact.uid == nil ? 0 : contact.rev,
            deleted: nil,
            fn: contact.name,
            givenName: contact.givenName.nilIfEmpty,
            familyName: contact.familyName.nilIfEmpty,
            middleName: contact.middleName.nilIfEmpty,
            prefix: contact.prefix.nilIfEmpty,
            suffix: contact.suffix.nilIfEmpty,
            nickname: contact.nickname.nilIfEmpty,
            org: contact.org.nilIfEmpty,
            title: contact.title.nilIfEmpty,
            emails: contact.emails.map { ContactFieldDTO(label: $0.label, value: $0.value) },
            phones: contact.phones.map { ContactFieldDTO(label: $0.label, value: $0.value) },
            addresses: contact.addresses.map {
                ContactAddressDTO(
                    label: $0.label,
                    street: $0.street,
                    city: $0.city,
                    region: $0.region,
                    postalCode: $0.postalCode,
                    country: $0.country
                )
            },
            notes: contact.notes.nilIfEmpty,
            birthday: contact.birthday.nilIfEmpty,
            photoRef: contact.photoRef,
            groupIDs: contact.groupIDs,
            pgpKey: contact.pgpKey,
            ims: contact.ims.map {
                ContactIMDTO(service: $0.service, label: $0.label, value: $0.value)
            },
            websites: contact.websites.map {
                ContactFieldDTO(label: $0.label, value: $0.value)
            },
            relations: contact.relations.map {
                ContactRelationDTO(label: $0.label, name: $0.name)
            },
            events: contact.events.map {
                ContactEventDTO(label: $0.label, date: $0.date)
            },
            phoneticGivenName: contact.phoneticGivenName.nilIfEmpty,
            phoneticFamilyName: contact.phoneticFamilyName.nilIfEmpty,
            department: contact.department.nilIfEmpty,
            customFields: contact.customFields.map {
                ContactCustomFieldDTO(label: $0.label, value: $0.value)
            },
            pronouns: contact.pronouns.nilIfEmpty
        )
    }

    /// Server `changed` entries carry the complete contact, so a missing
    /// field means empty — mapping falls back to `?? []` / `?? ""`, never to
    /// the existing value (that would resurrect fields cleared elsewhere).
    /// Only fields the server never sends (avatarUrl, local bookkeeping)
    /// keep their existing values.
    private func applyServerContact(uid: String, dto: ContactDTO) async throws {
        let now = Date()
        let existing = try await contactDAO.getContact(uid: uid)
        var contact = Contact(
            localId: existing?.localId ?? UUID(),
            uid: uid,
            rev: dto.rev ?? existing?.rev ?? 0,
            name: dto.fn ?? "",
            avatarUrl: existing?.avatarUrl,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            needsSync: false
        )
        contact.givenName = dto.givenName ?? ""
        contact.familyName = dto.familyName ?? ""
        contact.middleName = dto.middleName ?? ""
        contact.prefix = dto.prefix ?? ""
        contact.suffix = dto.suffix ?? ""
        contact.nickname = dto.nickname ?? ""
        contact.org = dto.org ?? ""
        contact.title = dto.title ?? ""
        contact.emails = (dto.emails ?? []).map {
            ContactLabeledValue(label: $0.label, value: $0.value)
        }
        contact.phones = (dto.phones ?? []).map {
            ContactLabeledValue(label: $0.label, value: $0.value)
        }
        contact.addresses = (dto.addresses ?? []).map {
            ContactPostalAddress(
                label: $0.label,
                street: $0.street,
                city: $0.city,
                region: $0.region,
                postalCode: $0.postalCode,
                country: $0.country
            )
        }
        contact.notes = dto.notes ?? ""
        contact.birthday = dto.birthday ?? ""
        contact.photoRef = dto.photoRef
        contact.groupIDs = dto.groupIDs ?? []
        Self.applyPgpKey(
            from: dto.pgpKey,
            existing: existing,
            // Survives a tooOld wipe, so a full re-pull can't present a
            // substituted key as a first sighting.
            rememberedKey: verifiedKeyStore?.key(forUid: uid),
            to: &contact
        )
        verifiedKeyStore?.remember(uid: uid, key: contact.pgpKey)
        contact.ims = (dto.ims ?? []).map {
            ContactIM(service: $0.service, label: $0.label, value: $0.value)
        }
        contact.websites = (dto.websites ?? []).map {
            ContactLabeledValue(label: $0.label, value: $0.value)
        }
        contact.relations = (dto.relations ?? []).map {
            ContactRelation(label: $0.label, name: $0.name)
        }
        contact.events = (dto.events ?? []).map {
            ContactEvent(label: $0.label, date: $0.date)
        }
        contact.phoneticGivenName = dto.phoneticGivenName ?? ""
        contact.phoneticFamilyName = dto.phoneticFamilyName ?? ""
        contact.department = dto.department ?? ""
        contact.customFields = (dto.customFields ?? []).map {
            ContactCustomField(label: $0.label, value: $0.value)
        }
        contact.pronouns = dto.pronouns ?? ""
        try await contactDAO.upsert(contacts: [contact])
    }

    /// A key received via sync that differs from an already-trusted key is
    /// held in `pendingPgpKey` for review instead of silently replacing it.
    /// The server is fully trusted for ordinary contact fields, but a PGP
    /// key's whole value is the out-of-band fingerprint verification the
    /// user did at QR-exchange time (ScanPgpKeyView) — a compromised relay
    /// could otherwise defeat that verification by swapping the key on the
    /// next routine sync, with no warning.
    ///
    /// **Clearing a trusted key counts as differing.** Treating a
    /// missing/empty incoming key as "apply immediately" was a two-step hole
    /// in exactly the guarantee above: entry one omits `pgpKey` and erases the
    /// verified key with no banner, entry two supplies the attacker's key and
    /// sails through because there is no longer a prior key to compare
    /// against. Both entries fit in a single sync response, since each is
    /// saved before the next is read. So a withdrawal keeps what the user
    /// verified and is ignored; only the user can remove a key they verified,
    /// from the contact screen.
    ///
    /// A pending review also survives a withdrawal — otherwise the same trick
    /// clears the banner instead of the key.
    ///
    /// `rememberedKey` is the last key this uid was trusted with, held outside
    /// SwiftData so it outlives a `tooOld` wipe. Without it the wipe was a
    /// laundering path: `clearAll()` removed the local row, so the re-pull saw
    /// no prior key and applied whatever the relay sent.
    private static func applyPgpKey(
        from incoming: String?,
        existing: Contact?,
        rememberedKey: String? = nil,
        to contact: inout Contact
    ) {
        // A wiped row has no key; fall back to what the user last verified.
        let existingKey = (existing?.pgpKey?.isEmpty == false)
            ? (existing?.pgpKey ?? "")
            : (rememberedKey ?? "")
        let incomingKey = incoming ?? ""

        // Nothing trusted yet: first key in wins, as before.
        guard !existingKey.isEmpty else {
            contact.pgpKey = incoming
            contact.pendingPgpKey = nil
            return
        }

        // Unchanged: clears any stale pending review (the server backed off).
        if incomingKey == existingKey {
            contact.pgpKey = existingKey
            contact.pendingPgpKey = nil
            return
        }

        // Withdrawn: keep the verified key and any pending review untouched.
        if incomingKey.isEmpty {
            contact.pgpKey = existingKey
            contact.pendingPgpKey = existing?.pendingPgpKey
            return
        }

        // Genuinely different: hold for the user to re-verify.
        contact.pgpKey = existingKey
        contact.pendingPgpKey = incomingKey
    }
}

private extension String {
    /// Empty scalars push as nil: the server's omitempty treats "" and
    /// absent identically, and nil keeps payloads small.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
