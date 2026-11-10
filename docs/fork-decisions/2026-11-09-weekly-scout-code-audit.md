2026-11-09: Arjun, asked whether the weekly exploration scout should run the vendored `improve` audit, answered "scout runs it but we want /improve to be a first class command and vendored in our arjmad/skills" and picked "Code audit, one repo per turn".
Decision: the weekly exploration scout rotates over four areas by ISO week modulo 4, the fourth a quick `improve` audit of one repository per turn, filed by firstmate as one batch.
The vendoring itself landed in https://github.com/arjmad/skills/pull/295.
Why: a quick trial on business at 05a4200 on 2026-11-09 took two sub-audits, about 530K sub-agent tokens and seven minutes, which fits one scout's weekly share.

| What | Files or functions | Upstream code touched | Status | Last checked sync |
| --- | --- | --- | --- | --- |
| The weekly exploration scout rotates modulo 4, adding a quick `improve` code audit of one repository per turn, with its repository order read from earlier audit reports | `.agents/skills/noticed-queue/SKILL.md` (Weekly exploration scout) | none | carried | c8d8fdad |
