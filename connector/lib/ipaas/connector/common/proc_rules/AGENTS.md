# Proc Rules Guidelines

The proc rules provide a first line of defense against malicious code.

Any change to the rules requires explicit mention in risk analysis and PRs and thorough review and automated test coverage.

Especially important to review and highlight are edits to:

- `RUBY_METHODS`
- `ADDITIONAL_METHODS`
- `ProcSafe.registry`
- `NOT_ALLOWED_NAMES`
- `NOT_ALLOWED_CLASS_NAMES`
- `ALLOWED_CONST_PATHS`
- `ALLOWED_WHOLE_CONST_PATHS`
- `REFLECTIVE_METHODS`
- `ProcHelper::TARGET_RUBY_VERSION`
- `ProcHelper::MAX_SOURCE_BYTES` and `Connector::MAX_SOURCE_FILE_BYTES` — both refuse before
  any parse, and are what keeps iPaaS from having to process too large content
- `ProcHelper::MAX_NESTING_DEPTH` — a source over it is refused before any rule sees it, thereby
  limiting what reaches the parser.

The two allowlists widen access rather than narrow it, so an addition needs the same scrutiny as a
removal from the blocked names. They answer different questions and are not interchangeable:

- `ALLOWED_CONST_PATHS` exempts a path whose **leaf** collides with a blocked name, and covers
  longer paths beneath it.
- `ALLOWED_WHOLE_CONST_PATHS` exempts one whole path whose **namespace root** is blocked. It is
  matched against the outermost constant of the path, so siblings under that root stay blocked.
  Reaching for it means a blocked namespace holds something narrow that is genuinely needed; a
  purpose-built `proc_safe` verb permits less and is the better answer where one is practical.

An entry there permits **reading** the path and nothing else, which takes two guards that are easy
to lose in a refactor. Both are covered by specs that fail without them:

- A permitted path is refused where it would be a **definition target** (`class << Foo::Bar`,
  `module Foo::Bar`, `Foo::Bar::X = 1`). No rule governs reopening a module, so permitting a path
  as a definition target would let a proc redefine or remove methods on it for the whole process.
- A permitted path is refused where it merely **starts a longer lookup**, including when an
  expression carries its value there first — `(Foo::Bar)::X`, `Foo::Bar.itself::X`,
  `[Foo::Bar][0]::X`. Without that, an entry naming a namespace that contains constants would
  expose all of them.

See the [spec guidelines](../../../../../spec/ipaas/connector/common/proc_rules/AGENTS.md) for more details on
writing automated tests for the proc rules.

## `helpers` is exempt here on purpose

`ValidMethodsRule#top_level_helper?` skips the allowlist for the first send off a receiverless
`helpers`, because the names in that position are connector-defined and no fixed list can hold
them. The control is the receiver, not the rule: `Helpers#for_proc` hands a proc a `HelpersProxy`
(a `BasicObject`) that dispatches registered helper names and nothing else.

Two consequences when changing anything here:

- A source such as `helpers.send(...)` is **accepted** by these rules and refused on dispatch. That
  is correct, not a gap. Regression cover lives in
  `../../../../../spec/ipaas/connector/common/helpers_proxy_spec.rb`, not in the specs beside these
  rules.
- Do not move that check into a rule. Such a rule would have to be aware of the helpers defined at
  the moment the proc is actually executed. This is not possible with static analysis (or at least
  very hard and error-prone): validation can run before the connector has finished registering, and
  its result is cached against the proc source alone, so the verdict would fall to whichever context
  happened to be validated first. The current approach lets a proc name anything on `helpers`, and
  refuses on dispatch everything the connector did not register — there is no list of permitted
  names to maintain.
