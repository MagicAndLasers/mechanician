# Mechanician Help corpus

`corpus.json` is the reviewed authoring authority for the product knowledge that ships with the
app. `scripts/build-help-corpus.mjs` validates it and produces the read-only
`MechanicianHelp.sqlite` resource used by both the Help window and agent-facing retrieval.

## Authoring rules

- Give every section, article, claim, evidence record, and demonstration a stable id. Claim keys
  are explicitly authored and namespaced by article (for example,
  `conversations.model-inheritance`); changing a Markdown heading must never silently rename a claim.
  Do not reuse an id after retiring its meaning.
- Demonstration ids are namespaced by their primary article. A demonstration declares a visible
  outcome, current claim grounding, exact canonical tool requirements, risk, reversibility, user
  confirmation, ordered steps, observed verification and bounded fallbacks. It is advice for an
  agent, never executable authority: the exact live conversation must still advertise every tool,
  and every call still passes its provider, app and macOS gates. A reported tool never promises
  that no approval will appear, even in a permissive conversation mode.
- Use only the compiler's closed demonstration-tool vocabulary. `observe` and `act` steps name one
  of those tools; `ask` and `explain` steps never do. An `act` requires
  `planCompatibleAction` for a classified in-app additive action or `executionEnabled` for an
  external action, plus explicit confirmation and verification tied to the action. Dynamic saved
  capabilities must keep dynamic risk and reversibility because the corpus cannot know their effects.
- Ground each demonstration in one or more existing claim keys. Current demonstrations may use
  only current claims. Fallbacks may explain a failure or name another demonstration, and the
  fallback graph must remain acyclic.
- Give every native guide a stable article-namespaced id and ground it in current signed claim
  keys. A guide is app-owned teaching data, not agent instructions or automation authority. It
  names one closed `surface`; ordered steps contain only reviewed copy plus `target`,
  `revealAction`, and `completion` values admitted on that surface. Reveal actions never carry a
  caller-selected id. `helpWorkspaceInspector` remains a manual reader tour started by the reader's
  own control. `conversationWorkspace` is the only agent-callable surface, so its guides are what
  the agent presents when someone asks to be shown a product surface.
- A `conversationWorkspace` guide is presented in the person's own conversation window and may name
  the Files, Changes, Artifacts, Agents, and Skills inspector tabs and the model, reasoning-effort,
  permission, and message-box controls. It never opens a workspace. Keep a guide's tab steps to
  surfaces one workspace can show at once, and remember that Files and Changes are refused in a
  folderless workspace, so a guide about either is honestly unavailable from Home.
- Ground each guide in the narrowest current claim that answers the request. Guide summaries are
  returned only for the claims a search actually matched, and only the first four survive, so a
  guide grounded in a catch-all overview claim competes with every sibling guide instead of
  answering the question that was asked.
- Guide text and schema must not encode raw workspace/window/conversation identifiers, URLs or
  URIs, scripts, coordinates, mutations, CSS/XPath/accessibility selectors, or another arbitrary
  UI locator or payload. Add a semantic surface, target, and native reveal action to the closed
  compiler and Swift vocabularies instead. Unknown fields fail the build rather than being ignored.
- Keep the article's long-form `markdown` as the human reading surface. Author each independently
  retrievable fact or procedure in `claims`, with an explicit lifecycle, ordinal, and list of
  `evidenceIDs`. The compiler never manufactures claims from headings or blurbs.
- Every claim must cite at least one evidence record from its article, and every evidence record
  must be used. Evidence paths must be tracked regular files inside the repository, with no symlink
  components. An anchor must occur exactly once.
- Evidence also carries a reviewed `sourceSHA256`. Any edit to the source file fails compilation
  until an author rereads the source, confirms that it still supports every linked claim, and
  deliberately updates the digest. The compiled database records that authored digest and a digest
  of the exact anchor.
- Author only `current` and `historical` lifecycle values today. Current search excludes historical
  claims unless the caller explicitly asks for history. `superseded` and `retired` require an
  explicit replacement/relation model before they can be represented honestly, so the corpus
  contract rejects them.
- Historical documents explain decisions but are not current specifications. A current article
  claim cannot rely only on `docs/history` evidence. The maintained History article contains only
  historical claims.
- Put exact symbols, flags, paths, and error phrases in aliases or claim text so technical lookup
  does not depend on prose normalization.
- Never add private strategy or tenant material to the public corpus. Tenant-specific knowledge
  belongs in a separately compiled tenant corpus.

Run this before handing off a corpus edit:

```sh
node scripts/build-help-corpus.mjs --check
```

The check validates schema and lifecycle vocabulary, stable claim/evidence mappings, demonstration
contracts and fallback graphs, guide grounding and closed native actions, source containment, Git
tracking, evidence digests, unique anchors, SQLite integrity and FTS parity, and two byte-for-byte
identical builds.
