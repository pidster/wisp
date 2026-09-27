# Labels and rules for the secrets set

The header the set was drafted with, then adjusted after review (see ../README.md and ../reviews/secrets.md).

```
Values that look like credentials carry an invisible U+200B after their fourth character, so secret
scanners (GitHub push protection, wisp's own scan) do not take this file for a leak. Every value is
invented. A loader strips U+200B before training, so a classifier never sees it.
secrets.tsv: one line of text as it appears in logs, config, source, shell history, env files, tickets,
chat, or stack traces, labelled `label<TAB>text`. Lines starting with # are comments.

Labels
  secret   - a credential: API key, token, password (any length, including in CLI flags), private key
             (BEGIN line or a body line), connection string with a password, cookie or session id,
             signed URL, Authorization header, JWT, webhook URL carrying a token, password hash, TOTP
             seed, registry auth (npm _authToken, docker config "auth"), a UUID the context says is a key.
  personal - personal or identifying data: a person's email, phone number, postal address, full name in
             context, government id, card number, date of birth, an IP tied to a person or request, and,
             as wisp's SecretScanner.Category.personal documents, a user name in a home path
             (/Users/<name>/, not /Users/Shared) and private hostnames (.internal, .corp, .lan, .local).
  none     - neither.

Judgement rules
  1. Synthesis convention: every value here is fake. Key-shaped values may carry EXAMPLE/FAKE markers or
     obviously invented sequences; the label is what the line would be if the value were live. Emails use
     example.com/example.org, phones 555 numbers, IPs the documentation ranges 192.0.2.0/24,
     198.51.100.0/24, 203.0.113.0/24, SSNs the invalid 9xx/000 ranges, UK NI numbers the QQ prefix, and
     cards Luhn-valid synthetic sequences.
  2. Placeholders and templates are none: <your-token>, ${TOKEN}, $API_KEY, {{ secrets.X }}, changeme,
     xxxxxxxx, ***, REDACTED, your-api-key-here, a truncated "sk-...", masked values like ghp_****abcd.
     Variable names without a value (API_KEY=) and references to a secret store (op://..., a Secrets
     Manager ARN, a Vault path) are none. Code that reads a secret from the environment is none.
  3. Emails: a person's address in logs, tickets, CRM rows, commit trailers, or chat is personal even on
     example.com (this diverges from SecretScanner, which skips every domain reserved for examples by
     design: here they stand in for real domains, rule 1; ADR 0031, amendment of 2026-09-27). Generic doc
     placeholders (you@example.com, user@example.com, name@domain.tld) and role or system addresses
     (noreply@, support@, alerts@, billing@, git@github.com) are none.
  4. IPs: an IP tied to a person, a login, or a client request is personal; private, loopback, and bind
     addresses, and server or infrastructure IPs in config, are none.
  5. Names: a full name in context (author, customer, patient, signer) is personal; a lone first name
     used as a stock example (Alice, Bob) is none; public project or company names are none.
  6. A line holding both a secret and personal data is secret (the more severe).
  7. Hard negatives are none: UUID request ids, git SHAs, content digests (sha256, sha512, md5 of files),
     lockfile integrity hashes, non-secret base64 (image data, protobuf, a public key), version strings,
     build ids, public keys and certificates (BEGIN PUBLIC KEY / CERTIFICATE, ssh-ed25519 AAAA...),
     Sentry DSNs (their key is public by Sentry's design), key ids and account ids (kid, AWS account id,
     AKIA-less key names), connection strings with no password, and documented test card numbers
     (4242 4242 4242 4242, 4111 1111 1111 1111) in test fixtures.
  8. A Firebase web config apiKey (AIza...) is secret, as the scanner treats it, though Google calls it
     public.
  9. Password hashes (bcrypt, sha512-crypt in a shadow line) are secret: crackable credential material.
  10. Added for the test set (2026-09-26): an account user name, a device id (MAC address, IMEI, VIN),
      precise coordinates, and a bank account number or IBAN are personal; a bank code alone (BIC,
      SWIFT, routing number, sort code) is none. A card's CVV, alone or with its card, is personal. A
      PIN that unlocks an account or a device is secret. A public figure's name in context is personal,
      like any other full name.

---------------------------------------------------------------------------------------------------
secret: env files and shell exports
```
