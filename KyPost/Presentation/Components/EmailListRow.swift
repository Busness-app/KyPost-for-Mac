//
//  EmailListRow.swift
//  KyPost
//
//  One inbox row: avatar, sender, subject, keyword chips, unread indicator.
//

import SwiftUI

struct EmailListRow: View {
    @Environment(\.theme) private var theme

    let email: Email

    private var rowPgpState: PgpMessageState {
        pgpMessageState(
            pgpEncrypted: email.pgpEncrypted,
            pgpDecryptError: email.pgpDecryptError,
            body: email.body
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: email.senderName.isEmpty ? email.senderEmail : email.senderName)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(email.senderName.isEmpty ? email.senderEmail : email.senderName)
                        .font(AppFont.ui(15, weight: email.read ? .regular : .semibold))
                        .foregroundStyle(theme.inkStrong)
                        .lineLimit(1)
                    Spacer()
                    Text(email.receivedAt, format: .relative(presentation: .named))
                        .font(AppFont.ui(12))
                        .foregroundStyle(theme.ink.opacity(0.7))
                }
                HStack(spacing: 5) {
                    if let symbol = pgpRowSymbol(rowPgpState) {
                        Image(systemName: symbol)
                            .font(AppFont.ui(12))
                            .foregroundStyle(theme.ink.opacity(0.8))
                    }
                    Text(email.subject)
                        .font(AppFont.ui(14, weight: email.read ? .regular : .medium))
                        .foregroundStyle(email.read ? theme.ink : theme.inkStrong)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    pgpRowAccessibilityLabel(state: rowPgpState, subject: email.subject) ?? email.subject
                )
                if !email.keywords.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(email.keywords.sorted(), id: \.self) { keyword in
                            Text(keyword)
                                .font(AppFont.ui(11, weight: .medium))
                                .foregroundStyle(theme.ink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().strokeBorder(theme.line, lineWidth: 1))
                        }
                    }
                }
            }

            if !email.read {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 6)
    }
}
