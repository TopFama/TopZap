# Quick WhatsApp conversations

The sidebar action opens a new conversation for an unsaved Brazilian phone number.
It resolves existing account contacts and WhatsApp contact inboxes using WhatsApp
Brazilian phone candidate equivalences (prioritizing exact matches, followed by
8/9-digit mobile variants, leaving landlines distinct) without renaming existing contacts.
It always creates a separate open conversation assigned to the requesting agent
(preserving manual assignment to administrators even when auto-assignment is enabled,
and preserving open status when active bots are present on the inbox, respecting contact
blocklists). Inbox access and the existing assignment cap apply.

`POST /api/v1/accounts/:account_id/topzap/quick_conversations` accepts
`inbox_id`, `phone_number` (+55 plus 10–11 digits), `name`, and JSON boolean
`send_csat`. Only accessible WhatsApp Cloud inboxes are allowed. Missing or
unapproved templates return 422 before writes. The name/language pair must match
an APPROVED entry in the inbox's synced message templates. Sync templates before
use; approval can subsequently change at Meta and delivery can still fail.

With `send_csat: true`, the configured CSAT template is used (no fixed template
name). A native outgoing `input_csat` message contains the configured CSAT text
and a URL button parameter with the new conversation UUID. The native SendReplyJob
sends the template after database commit and records the provider source_id.
Delivery errors remain visible in the conversation. The API's 201 means created
and queued, not delivered. Successful job replay is skipped by native source_id
protection. The public survey controller and native response builder/report are
unchanged; the survey retains the native 14-day response limit.

To prevent duplicate CSAT sends upon later conversation resolution, quick CSAT
conversations ensure the `csat_enviado` label exists on the account (`show_on_sidebar: true`),
tag the conversation with `csat_enviado`, and register `csat_enviado` in the inbox's
`csat_config['survey_rules']` under `does_not_contain` while preserving existing rules
(such as `"MKT - JULIA"`). Additionally, `CsatSurveyService#should_send_csat_survey?`
explicitly blocks resolution surveys if the conversation carries `csat_enviado`
(even if an inbox operator is configured with `contains`), guaranteeing that resolving
the conversation never triggers a second survey or window-expired activity message.

With `send_csat: false`, `content` and `template_params` use the existing WhatsApp
parser and message builder. The supplied template must also match an approved
name/language pair. Free text without a template is rejected. The `csat_enviado` tag
is not applied, allowing normal resolution surveys if configured. No migrations are needed.

## Packaging

Dockerfile.statusfilter appends COPY instructions for routes, the new controller,
service and exception, and CsatSurveyService. Existing locale COPY instructions
already include the changed en/pt_BR files. Branding and enterprise premium config
are untouched. Build public/vite from this checkout before building the image.
Generated Vite assets are ignored by git as in the existing project.

## Verification

- `corepack pnpm install --frozen-lockfile --ignore-scripts`
- `corepack pnpm exec vitest run app/javascript/dashboard/components-next/NewConversation/helpers/__tests__/quickConversationHelper.spec.js --no-coverage`
- `corepack pnpm exec eslint app/javascript/dashboard/components-next/NewConversation/QuickConversation.vue app/javascript/dashboard/components-next/NewConversation/helpers/quickConversationHelper.js app/javascript/dashboard/components-next/NewConversation/helpers/__tests__/quickConversationHelper.spec.js app/javascript/dashboard/components-next/sidebar/Sidebar.vue --max-warnings 0`
- `bundle exec rspec spec/controllers/api/v1/accounts/topzap/quick_conversations_controller_spec.rb spec/services/topzap/quick_csat_delivery_spec.rb`
- `bundle exec rubocop app/services/csat_survey_service.rb app/services/topzap/quick_conversation_service.rb app/controllers/api/v1/accounts/topzap/quick_conversations_controller.rb lib/custom_exceptions/quick_conversation_error.rb spec/controllers/api/v1/accounts/topzap/quick_conversations_controller_spec.rb spec/services/topzap/quick_csat_delivery_spec.rb`
- `corepack pnpm exec vite build`

The implementation environment has Node 22.17.0 (repository requests 24.x).
Ruby/Bundler and a running Docker engine are unavailable: the Ruby commands
cannot run here and need the project's Ruby 3.4.4/Postgres/Redis test environment.
RSpec coverage includes new/existing contacts, Brazilian 8/9-digit mobile equivalence,
landline isolation, one conversation per request, permissions, validation,
missing/wrong-language templates, assignment cap rollback (including with active bots),
admin auto-assignment preservation, blocked contact resolution, optional templates,
native survey submission/report storage, and native template job delivery/source_id/replay.
These specs are authored, not confirmed passing.
No production access, real database, real WhatsApp messages, merge or deployment
was used for this change.

Observed results in this checkout: Vitest 13/13 passed; ESLint 0 errors/0 warnings;
Vite production build passed; en/pt_BR YAML and JSON parsed;
`git diff --check` passed. Build warnings: outdated Browserslist data and large
chunks. RSpec and RuboCop could not start because `bundle` is not installed.
