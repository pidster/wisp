# ADR 0042: A personal-data classifier beside the rules in scan_secrets

Date: 2026-09-28. Status: accepted. Builds on [ADR 0031](0031-secret-scanning-and-redaction.md) and
[ADR 0038](0038-fast-specialised-classifiers.md); amends ADR 0038's rule that a shipped classifier can
be reproduced from its examples, for this classifier only.

## Context

On the secrets test set, 645 lines of third-party synthetic data (`training/secrets/`), the rules find
27 of 218 personal-data lines (12%). The on-device model's thorough pass finds 144 of them, at about
10 s per 4 KiB. Personal data is mostly context, not shape: a name after "assigned to", an account
holder, an address outside the "number, name, Street" form. That is where a learned classifier should
help and a regex cannot.

The classifiers measured before this one each did two jobs at once. A three-way classifier (`secret`,
`personal`, `none`) found more secrets than rules + model, but flagged 130 ordinary or personal lines as
secret, and it was worse than the model at personal data. Splitting the job, as the operator
suggested, gave one classifier per category, and the two behaved differently. Each was chosen on dev
(transfer learning on dynamic, ELMo-style contextual embeddings, `.elmoEmbedding` in Create ML, from five variants) and scored once on test:

| Added to rules + on-device model | Secrets found / false | Personal found / false | Macro-F1 |
| --- | --- | --- | --- |
| nothing (the thorough pass as it was) | 132 / 48 | 144 / 38 | 0.67 |
| a secret-only classifier | 172 / 117 | 121 / 31 | 0.64 |
| a personal-only classifier | 132 / 48 | 185 / 65 | 0.69 |

The secret-only classifier bought 40 secrets for 69 false alarms, since secrets are shapes and the
rules already know shapes. The personal-only classifier was the best of everything measured.

**It cannot be trained reproducibly.** ADR 0038 fixed maxEnt's run-to-run variation with
`validation: .none`, which stops Create ML holding back a random slice. Transfer learning ignores that
setting and still holds back a random tenth to decide when to stop. Across six runs the models disagreed
on 11 to 13 of the 93 dev lines, with dev F1 from 0.70 to 0.78. Giving it the dev set as an explicit
validation set stops the hold-back, so all 527 training lines train. The disagreement then falls to 2 to
4 lines. The rest is the network's random start, which Create ML has no seed for.

## Decision

- **`PersonalDataClassifier`** is a Core ML text classifier over one line, with labels `personal` and
  `other`. It is trained by `PersonalDataTraining` on `training/secrets/train.tsv`, where `secret` and
  `none` both count as `other`. The dev set is its validation set. Contract 1 is written in the model's
  metadata under the risk classifier's keys and checked at load.
- **The file is the classifier.** `Resources/personal-default.json` embeds the manifest and the model
  (1.5 MB, 2 MB in base64), as the risk default is embedded. `wisp classifier ship --task personal
  --examples training/secrets/train.tsv --validation training/secrets/dev.tsv --classifier-version <n>`
  writes it.
  It runs only when the personal training set changes, and never at a version bump: `scripts/check
  classifier-default` ships only risk. A new file is measured on test before it replaces the old one, and
  its version goes up by one. It is reproducible as a file, not from its examples.
- **Where it runs.** `scan_secrets` and `wisp scan` run it when personal data is asked for, with or
  without `thorough`, since it costs about 2 ms a line. It judges each line (a diff's added lines) where
  neither the rules nor the model found anything. It reports the line as `personal-data`, detector
  `classifier`, with the line masked as the preview.
- **What it reports.** The result's `classifier` field names `personal@<version>`, or says why it was
  unavailable, in which case the scan goes on without it. The `secrets.scan` audit event records it too.
- **Not in `redact`.** It says which line, not which value, so `redact` does not use it.

## Consequences

Measured on 2026-09-28, the shipped file `personal@1` scored once on test (`wisp classifier baseline
--task secrets --classifier`, and the thorough run of ADR 0031's second amendment of 2026-09-27):

| On 645 test lines | Personal found (of 218) | Personal false alarms | Macro-F1 |
| --- | --- | --- | --- |
| rules | 27 (12%) | 14 | 0.40 |
| **rules + `personal@1`: `--personal`** | **135 (62%)** | **45** | **0.57** |
| rules + model: `--personal --thorough` before | 144 (66%) | 38 | 0.67 |
| rules + model + `personal@1`: `--personal --thorough` now | 175 (80%) | 62 | 0.68 |

- **Without the model, a personal scan finds five times as much.** 645 lines take 1.5 s in all,
  loading included, against 0.06 s for secrets alone. A secrets-only scan never loads the model.
- **With the model, it adds** 31 personal lines for 24 more false alarms.
- **Secrets are unchanged.** It never flags a secret.
- **Dev is optimistic here.** Dev is both the choosing set and the validation set, and scored 0.88 with
  the rules, against 0.57 on test. Test is the figure to trust.
- **The binary grows by the embedded 2 MB.** The build is not measurably slower.
- **It is the one exception to the 1 MiB file limit.** The hygiene check in `scripts/check` names it,
  since the weights do not compress (1.49 MB raw, 1.36 MB with LZMA). Each retraining adds about 2 MB to
  the repository's history. Another file joins that list only with an ADR that says why.
- **Tests without the model:** the shipped file loads and flags a known line; the preprocessing; an
  empty resource; a scan where the classifier finds a line the rules did not and leaves one the rules
  found; a diff's located line; a secrets-only scan that does not run it; an unavailable classifier
  reported; and the audit fields.
