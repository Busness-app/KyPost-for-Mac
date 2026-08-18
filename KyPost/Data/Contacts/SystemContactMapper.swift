//
//  SystemContactMapper.swift
//  KyPost
//
//  Pure Contact -> CNMutableContact field mapping. `apply` only touches the
//  mapped fields so anything the user added to a card in Contacts.app
//  survives re-exports. Never writes `note`: that requires the restricted
//  com.apple.developer.contacts.notes entitlement. pgpKey, pronouns,
//  customFields, and groupIDs have no CNContact data kind and stay app-only
//  (Client_Contact_Update.md Part 5).
//

import Contacts
import Foundation

enum SystemContactMapper {
    static let avatarUrlLabel = "Avatar"

    static let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactMiddleNameKey,
        CNContactNamePrefixKey,
        CNContactNameSuffixKey,
        CNContactNicknameKey,
        CNContactPhoneticGivenNameKey,
        CNContactPhoneticFamilyNameKey,
        CNContactEmailAddressesKey,
        CNContactPhoneNumbersKey,
        CNContactPostalAddressesKey,
        CNContactUrlAddressesKey,
        CNContactOrganizationNameKey,
        CNContactJobTitleKey,
        CNContactDepartmentNameKey,
        CNContactBirthdayKey,
        CNContactDatesKey,
        CNContactInstantMessageAddressesKey,
        CNContactSocialProfilesKey,
        CNContactRelationsKey,
        CNContactImageDataKey,
    ] as [CNKeyDescriptor]

    // MARK: - IM / social service catalog

    /// Single source of truth for the backend's fixed IM service vocabulary
    /// (matches the web frontend's IM_SERVICES list). Messaging services map
    /// to instantMessageAddresses, social networks to socialProfiles; no
    /// built-in CN service constant exists for most of them, so the display
    /// name doubles as the CN service string.
    struct IMService {
        var code: String
        var displayName: String
        var isSocial: Bool
        var cnSocialService: String?
    }

    static let imServiceCatalog: [IMService] = [
        IMService(code: "whatsapp", displayName: "WhatsApp", isSocial: false, cnSocialService: nil),
        IMService(code: "signal", displayName: "Signal", isSocial: false, cnSocialService: nil),
        IMService(code: "telegram", displayName: "Telegram", isSocial: false, cnSocialService: nil),
        IMService(code: "matrix", displayName: "Matrix", isSocial: false, cnSocialService: nil),
        IMService(
            code: "instagram", displayName: "Instagram", isSocial: true, cnSocialService: nil
        ),
        IMService(code: "x", displayName: "X", isSocial: true, cnSocialService: nil),
        IMService(
            code: "linkedin", displayName: "LinkedIn", isSocial: true,
            cnSocialService: CNSocialProfileServiceLinkedIn
        ),
        IMService(
            code: "facebook", displayName: "Facebook", isSocial: true,
            cnSocialService: CNSocialProfileServiceFacebook
        ),
        IMService(code: "mastodon", displayName: "Mastodon", isSocial: true, cnSocialService: nil),
    ]

    static func imService(code: String?) -> IMService? {
        guard let code, !code.isEmpty else { return nil }
        return imServiceCatalog.first { $0.code == code.lowercased() }
    }

    private static func imService(displayNameOrCNService name: String) -> IMService? {
        let lowered = name.lowercased()
        // CN's own Twitter constant predates the X rename.
        if lowered == "twitter" { return imService(code: "x") }
        return imServiceCatalog.first {
            $0.code == lowered
                || $0.displayName.lowercased() == lowered
                || $0.cnSocialService?.lowercased() == lowered
        }
    }

    // MARK: - Names

    /// Splits on the last whitespace: "Ada M. Lovelace" -> ("Ada M.", "Lovelace").
    /// Empty names fall back to the email local-part so cards aren't blank.
    static func nameComponents(
        from name: String,
        fallbackEmail: String
    ) -> (given: String, family: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let localPart = fallbackEmail.split(separator: "@").first.map(String.init)
            return (localPart ?? "", "")
        }
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        guard parts.count > 1 else { return (trimmed, "") }
        return (parts.dropLast().joined(separator: " "), String(parts.last!))
    }

    static func makeContact(from contact: Contact, photoData: Data? = nil) -> CNMutableContact {
        let cn = CNMutableContact()
        apply(contact, to: cn, photoData: photoData)
        return cn
    }

    // MARK: - Match keys

    /// De-dupe identity across the app and Contacts.app: primary email when
    /// present (case-insensitive), else name + phone digits. Nil when there
    /// isn't enough signal to match safely.
    nonisolated static func matchKey(name: String, email: String, phone: String) -> String? {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !email.isEmpty { return "email:\(email)" }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = phone.filter(\.isNumber)
        guard !name.isEmpty, !digits.isEmpty else { return nil }
        return "name+phone:\(name)|\(digits)"
    }

    nonisolated static func matchKey(for contact: Contact) -> String? {
        matchKey(name: contact.name, email: contact.primaryEmail, phone: contact.primaryPhone)
    }

    /// Every identity an app contact can match under: one key per email
    /// address, else the name+phone fallback.
    ///
    /// The card side has always offered every email; this side used to offer
    /// only `primaryEmail`, and that asymmetry duplicated people. A contact
    /// holding two addresses whose card carries only the second one matched
    /// nothing: adoption skipped it and exported a second card, and the
    /// import pass then read that same card as a person the app had never
    /// heard of and created a second *contact* — one queued for the relay, so
    /// the duplicate propagated to the server and every other device.
    /// Both sides must offer every identity they have, or a pair can each
    /// hold a key the other never presents.
    nonisolated static func matchKeys(for contact: Contact) -> [String] {
        let emailKeys = contact.emails.compactMap {
            matchKey(name: contact.name, email: $0.value, phone: "")
        }
        if !emailKeys.isEmpty { return emailKeys }
        return matchKey(name: contact.name, email: "", phone: contact.primaryPhone)
            .map { [$0] } ?? []
    }

    /// Every identity a card can match under: one key per email address,
    /// else the name+phone fallback.
    static func matchKeys(for cn: CNContact) -> [String] {
        let name = [cn.givenName, cn.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let emailKeys = cn.emailAddresses.compactMap {
            matchKey(name: name, email: $0.value as String, phone: "")
        }
        if !emailKeys.isEmpty { return emailKeys }
        let phone = cn.phoneNumbers.first?.value.stringValue ?? ""
        return matchKey(name: name, email: "", phone: phone).map { [$0] } ?? []
    }

    // MARK: - Import (Contacts.app -> app contact)

    /// Reverse mapping for sync-back: a card added in Contacts.app becomes a
    /// local app contact queued for the next relay push.
    static func contact(from cn: CNContact) -> Contact {
        let now = Date()
        var contact = Contact(
            name: [cn.givenName, cn.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            avatarUrl: nil,
            createdAt: now,
            updatedAt: now,
            needsSync: true
        )
        contact.givenName = cn.givenName
        contact.familyName = cn.familyName
        contact.middleName = cn.middleName
        contact.prefix = cn.namePrefix
        contact.suffix = cn.nameSuffix
        contact.nickname = cn.nickname
        contact.phoneticGivenName = cn.phoneticGivenName
        contact.phoneticFamilyName = cn.phoneticFamilyName
        contact.org = cn.organizationName
        contact.title = cn.jobTitle
        contact.department = cn.departmentName
        contact.emails = cn.emailAddresses.map {
            ContactLabeledValue(label: wireLabel(fromCNLabel: $0.label), value: $0.value as String)
        }
        contact.phones = cn.phoneNumbers.map {
            ContactLabeledValue(label: wireLabel(fromCNLabel: $0.label), value: $0.value.stringValue)
        }
        contact.addresses = cn.postalAddresses.map {
            ContactPostalAddress(
                label: wireLabel(fromCNLabel: $0.label),
                street: $0.value.street.isEmpty ? nil : $0.value.street,
                city: $0.value.city.isEmpty ? nil : $0.value.city,
                region: $0.value.state.isEmpty ? nil : $0.value.state,
                postalCode: $0.value.postalCode.isEmpty ? nil : $0.value.postalCode,
                country: $0.value.country.isEmpty ? nil : $0.value.country
            )
        }
        contact.websites = cn.urlAddresses
            .filter { $0.label != avatarUrlLabel }
            .map {
                ContactLabeledValue(
                    label: wireLabel(fromCNLabel: $0.label),
                    value: $0.value as String
                )
            }
        if let birthday = cn.birthday, let iso = isoDate(from: birthday) {
            contact.birthday = iso
        }
        contact.events = cn.dates.compactMap { entry in
            guard let iso = isoDate(from: entry.value as DateComponents) else { return nil }
            let label = entry.label == CNLabelDateAnniversary
                ? "anniversary"
                : wireLabel(fromCNLabel: entry.label)
            return ContactEvent(label: label, date: iso)
        }
        contact.ims = cn.instantMessageAddresses.map { entry in
            im(serviceName: entry.value.service, handle: entry.value.username)
        } + cn.socialProfiles.map { entry in
            im(serviceName: entry.value.service, handle: entry.value.username)
        }
        contact.relations = cn.contactRelations.map {
            ContactRelation(
                label: relationWireLabel(fromCNLabel: $0.label),
                name: $0.value.name
            )
        }
        if contact.name.isEmpty {
            // Contacts.app allows cards without a personal name (company-only
            // cards), but the server rejects creates without an fn.
            contact.name = contact.derivedDisplayName
        }
        return contact
    }

    private static func im(serviceName: String, handle: String) -> ContactIM {
        if let service = imService(displayNameOrCNService: serviceName) {
            return ContactIM(service: service.code, label: nil, value: handle)
        }
        // Unknown service: backend "other" convention — empty service code,
        // free-text name in label.
        return ContactIM(
            service: nil,
            label: serviceName.isEmpty ? nil : serviceName,
            value: handle
        )
    }

    // MARK: - Export (app contact -> Contacts.app)

    static func apply(_ contact: Contact, to cn: CNMutableContact, photoData: Data? = nil) {
        if contact.givenName.isEmpty && contact.familyName.isEmpty {
            let (given, family) = nameComponents(
                from: contact.name,
                fallbackEmail: contact.primaryEmail
            )
            cn.givenName = given
            cn.familyName = family
        } else {
            cn.givenName = contact.givenName
            cn.familyName = contact.familyName
        }
        cn.middleName = contact.middleName
        cn.namePrefix = contact.prefix
        cn.nameSuffix = contact.suffix
        cn.nickname = contact.nickname
        cn.phoneticGivenName = contact.phoneticGivenName
        cn.phoneticFamilyName = contact.phoneticFamilyName
        cn.organizationName = contact.org
        cn.jobTitle = contact.title
        cn.departmentName = contact.department

        cn.emailAddresses = contact.emails.map {
            CNLabeledValue(
                label: cnLabel(fromWireLabel: $0.label, fallback: CNLabelHome),
                value: $0.value as NSString
            )
        }
        cn.phoneNumbers = contact.phones.map {
            CNLabeledValue(
                label: cnLabel(fromWireLabel: $0.label, fallback: CNLabelPhoneNumberMain),
                value: CNPhoneNumber(stringValue: $0.value)
            )
        }
        cn.postalAddresses = contact.addresses.map { address in
            let postal = CNMutablePostalAddress()
            postal.street = address.street ?? ""
            postal.city = address.city ?? ""
            postal.state = address.region ?? ""
            postal.postalCode = address.postalCode ?? ""
            postal.country = address.country ?? ""
            return CNLabeledValue(
                label: cnLabel(fromWireLabel: address.label, fallback: CNLabelHome),
                value: postal
            )
        }

        // The avatar entry keeps its slot ahead of real websites; both live
        // in urlAddresses.
        let avatarEntries = contact.avatarUrl.map {
            [CNLabeledValue(label: Self.avatarUrlLabel, value: $0 as NSString)]
        } ?? []
        cn.urlAddresses = avatarEntries + contact.websites.map {
            CNLabeledValue(
                label: cnLabel(fromWireLabel: $0.label, fallback: CNLabelURLAddressHomePage),
                value: $0.value as NSString
            )
        }

        cn.birthday = dateComponents(fromISODate: contact.birthday)
        cn.dates = contact.events.compactMap { event in
            guard let components = dateComponents(fromISODate: event.date) else { return nil }
            let label = event.label?.lowercased() == "anniversary"
                ? CNLabelDateAnniversary
                : cnLabel(fromWireLabel: event.label, fallback: CNLabelOther)
            return CNLabeledValue(label: label, value: components as NSDateComponents)
        }

        var imEntries: [CNLabeledValue<CNInstantMessageAddress>] = []
        var socialEntries: [CNLabeledValue<CNSocialProfile>] = []
        for entry in contact.ims {
            if let service = imService(code: entry.service), service.isSocial {
                socialEntries.append(CNLabeledValue(
                    label: nil,
                    value: CNSocialProfile(
                        urlString: nil,
                        username: entry.value,
                        userIdentifier: nil,
                        service: service.cnSocialService ?? service.displayName
                    )
                ))
            } else {
                let serviceName = imService(code: entry.service)?.displayName
                    ?? entry.label
                    ?? "IM"
                imEntries.append(CNLabeledValue(
                    label: nil,
                    value: CNInstantMessageAddress(username: entry.value, service: serviceName)
                ))
            }
        }
        cn.instantMessageAddresses = imEntries
        cn.socialProfiles = socialEntries

        cn.contactRelations = contact.relations.map {
            CNLabeledValue(
                label: cnRelationLabel(fromWireLabel: $0.label),
                value: CNContactRelation(name: $0.name)
            )
        }

        // Only ever set, never cleared: a user-chosen photo in Contacts.app
        // survives until the server actually has bytes for this contact.
        if let photoData {
            cn.imageData = photoData
        }
    }

    // MARK: - Label mapping

    /// Wire labels are freeform lowercase strings ("home", "work", "mobile");
    /// CN wants its localized _$!<…>!$_ constants for the common ones.
    static func cnLabel(fromWireLabel label: String?, fallback: String) -> String {
        guard let label, !label.isEmpty else { return fallback }
        switch label.lowercased() {
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "other": return CNLabelOther
        case "mobile", "cell": return CNLabelPhoneNumberMobile
        case "main": return CNLabelPhoneNumberMain
        case "homepage": return CNLabelURLAddressHomePage
        case "anniversary": return CNLabelDateAnniversary
        default: return label
        }
    }

    /// Inverse of `cnLabel`: known constants back to wire vocabulary, other
    /// _$!<Name>!$_ constants to their lowercased inner name, custom labels
    /// pass through, empty to nil.
    static func wireLabel(fromCNLabel label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        switch label {
        case CNLabelHome: return "home"
        case CNLabelWork: return "work"
        case CNLabelOther: return "other"
        case CNLabelPhoneNumberMobile: return "mobile"
        case CNLabelPhoneNumberMain: return "main"
        case CNLabelURLAddressHomePage: return "homepage"
        case CNLabelDateAnniversary: return "anniversary"
        default:
            if label.hasPrefix("_$!<"), label.hasSuffix(">!$_") {
                return String(label.dropFirst(4).dropLast(4)).lowercased()
            }
            return label
        }
    }

    /// Backend relation vocabulary → CNLabelContactRelation* constants;
    /// "relative"/"other"/unknown keep the raw string as a custom label.
    static func cnRelationLabel(fromWireLabel label: String?) -> String? {
        switch label?.lowercased() {
        case "spouse": return CNLabelContactRelationSpouse
        case "child": return CNLabelContactRelationChild
        case "parent": return CNLabelContactRelationParent
        case "partner": return CNLabelContactRelationPartner
        case "manager": return CNLabelContactRelationManager
        case "assistant": return CNLabelContactRelationAssistant
        case "friend": return CNLabelContactRelationFriend
        default: return label
        }
    }

    static func relationWireLabel(fromCNLabel label: String?) -> String? {
        switch label {
        case CNLabelContactRelationSpouse: return "spouse"
        case CNLabelContactRelationChild: return "child"
        case CNLabelContactRelationParent: return "parent"
        case CNLabelContactRelationPartner: return "partner"
        case CNLabelContactRelationManager: return "manager"
        case CNLabelContactRelationAssistant: return "assistant"
        case CNLabelContactRelationFriend: return "friend"
        default: return wireLabel(fromCNLabel: label)
        }
    }

    // MARK: - Dates

    /// "YYYY-MM-DD" -> DateComponents; nil for anything unparseable (server
    /// data must never crash the export).
    static func dateComponents(fromISODate string: String) -> DateComponents? {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    static func isoDate(from components: DateComponents) -> String? {
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
