# Help expertise evaluations

These files make the current Help expert's limits reviewable without turning an evaluation into
product authority.

- [`../expertise-coverage.json`](../expertise-coverage.json) assigns every signed claim to one
  major subsystem. A subsystem may be `covered`, `partial`, or `gap`; partial and gap entries are
  valid only when they name what is missing. Adding a claim requires an explicit reassessment, but
  an honestly declared gap does not fail the build.
- [`golden-questions.json`](golden-questions.json) contains deterministic questions for current
  retrieval, history opt-in, evidence links, and lexical abstention.
- [`../../scripts/test/help-expertise.test.mjs`](../../scripts/test/help-expertise.test.mjs)
  compiles the reviewed corpus, runs the same question-mode FTS expression and ranking contract as
  the app, and checks the fixtures against the built database.

Run the focused gate with:

```sh
node --test scripts/test/help-expertise.test.mjs
```

This is a retrieval and coverage contract, not a claim that the provider will compose a perfect
answer. It deliberately does not evaluate prose quality, semantic recall, live capability advice,
or runtime diagnosis. Those need separate provider-level and diagnostic evaluations. Unsupported
goldens use terms absent from the corpus and prove that the lexical retriever returns nothing; they
do not prove general semantic abstention.
