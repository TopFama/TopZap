require 'rails_helper'

RSpec.describe 'Quick WhatsApp conversations API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                              validate_provider_config: false, sync_templates: false,
                              message_templates: [template])
  end
  let(:inbox) do
    create(:inbox, account: account, channel: channel, csat_survey_enabled: true,
                   csat_config: { template: { name: template['name'], language: 'pt_BR' }, message: 'Avalie seu atendimento' })
  end
  let(:template) do
    { 'name' => 'customer_satisfaction_survey_92', 'language' => 'pt_BR', 'status' => 'APPROVED',
      'components' => [{ 'type' => 'BODY', 'text' => 'Avalie seu atendimento' },
                       { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'URL', 'url' => 'https://example.test/survey/responses/{{1}}' }] }] }
  end
  let(:path) { "/api/v1/accounts/#{account.id}/topzap/quick_conversations" }
  let(:params) { { inbox_id: inbox.id, phone_number: '+5511999998888', name: 'Cliente novo', send_csat: true } }

  before do
    create(:inbox_member, user: agent, inbox: inbox)
  end

  it 'creates the contact, digit-only source and an open assigned conversation' do
    expect do
      post path, headers: agent.create_new_auth_token, params: params, as: :json
    end.to change(account.contacts, :count).by(1)
    expect(response).to have_http_status(:created)
    conversation = account.conversations.last
    expect(conversation).to be_open
    expect(conversation.assignee).to eq(agent)
    expect(conversation.contact.name).to eq('Cliente novo')
    expect(conversation.contact_inbox.source_id).to eq('5511999998888')
    expect(JSON.parse(response.body)['id']).to eq(conversation.display_id)
  end

  it 'attaches an outgoing CSAT template survey message with conversation uuid' do
    post path, headers: agent.create_new_auth_token, params: params, as: :json
    conversation = account.conversations.last
    message = conversation.messages.input_csat.last
    expect(message).to be_outgoing
    expect(message.content).to eq('Avalie seu atendimento')
    expect(message.additional_attributes.dig('template_params', 'processed_params', 'buttons', 0, 'parameter')).to eq(conversation.uuid)
  end

  it 'reuses the existing contact without overwriting their name and always creates a new conversation' do
    contact = create(:contact, account: account, name: 'Nome original', phone_number: params[:phone_number])
    2.times { post path, headers: agent.create_new_auth_token, params: params, as: :json }
    expect(response).to have_http_status(:created)
    expect(contact.reload.name).to eq('Nome original')
    expect(contact.conversations.count).to eq(2)
    expect(contact.contact_inboxes.where(inbox: inbox).count).to eq(1)
  end

  it 'rejects an unapproved CSAT template before creating data' do
    channel.update!(message_templates: [])
    expect do
      post path, headers: agent.create_new_auth_token, params: params, as: :json
    end.not_to change(account.contacts, :count)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects an approved template with a different language' do
    inbox.update!(csat_config: { template: { name: template['name'], language: 'en' } })
    post path, headers: agent.create_new_auth_token, params: params, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects invalid Brazilian numbers' do
    post path, headers: agent.create_new_auth_token, params: params.merge(phone_number: '+5411999998888'), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects a blank name' do
    post path, headers: agent.create_new_auth_token, params: params.merge(name: ' '), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects an inbox the agent cannot access' do
    inbox.inbox_members.destroy_all
    post path, headers: agent.create_new_auth_token, params: params, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'requires authentication' do
    post path, params: params, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects inboxes from another account' do
    other_inbox = create(:inbox)
    post path, headers: agent.create_new_auth_token, params: params.merge(inbox_id: other_inbox.id), as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'rolls back without sending when assignment capacity is exceeded' do
    agent.account_users.find_by!(account: account).update!(max_open_conversations: 1)
    create(:conversation, account: account, inbox: inbox, assignee: agent, status: :open)
    expect do
      post path, headers: agent.create_new_auth_token, params: params, as: :json
    end.not_to change(account.conversations, :count)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'allows another approved template without CSAT' do
    payload = params.merge(send_csat: false, content: 'Template',
                           template_params: { name: template['name'], language: 'pt_BR', processed_params: {} })
    post path, headers: agent.create_new_auth_token, params: payload, as: :json
    expect(response).to have_http_status(:created)
    expect(account.conversations.last.messages.input_csat).to be_empty
  end

  it 'exposes the native public survey and stores a response for the native report' do
    post path, headers: agent.create_new_auth_token, params: params, as: :json
    conversation = account.conversations.last
    message = conversation.messages.input_csat.last
    get "/public/api/v1/csat_survey/#{conversation.uuid}"
    expect(response).to have_http_status(:ok)
    patch "/public/api/v1/csat_survey/#{conversation.uuid}",
          params: { message: { submitted_values: { csat_survey_response: { rating: 5, feedback_message: 'Excelente' } } } }, as: :json
    expect(response).to have_http_status(:ok)
    # Run the native listener's builder explicitly; event dispatch is asynchronous.
    CsatSurveys::ResponseBuilder.new(message: message.reload).perform
    survey = account.csat_survey_responses.find_by!(conversation: conversation)
    expect(survey.rating).to eq(5)
    expect(survey.assigned_agent).to eq(agent)
    expect(survey.feedback_message).to eq('Excelente')
  end

  it 'does not allow free text as the first message' do
    post path, headers: agent.create_new_auth_token, params: params.merge(send_csat: false, content: 'Free text'), as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'enforces assignment capacity and rolls back when an active bot is configured on the inbox' do
    agent.account_users.find_by!(account: account).update!(max_open_conversations: 1)
    create(:conversation, account: account, inbox: inbox, assignee: agent, status: :open)
    create(:agent_bot_inbox, inbox: inbox, agent_bot: create(:agent_bot), status: :active)

    expect do
      post path, headers: agent.create_new_auth_token, params: params, as: :json
    end.not_to change(account.conversations, :count)

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'ensures the conversation is open even when an active agent bot is present' do
    create(:agent_bot_inbox, inbox: inbox, agent_bot: create(:agent_bot), status: :active)

    post path, headers: agent.create_new_auth_token, params: params, as: :json
    expect(response).to have_http_status(:created)
    conversation = account.conversations.last
    expect(conversation).to be_open
    expect(conversation.assignee).to eq(agent)
  end

  it 'preserves manual assignment to an administrator who is not an inbox member when auto-assignment is enabled' do
    admin = create(:user, account: account, role: :administrator)
    other_member = create(:user, account: account, role: :agent)
    create(:inbox_member, user: other_member, inbox: inbox)
    inbox.update!(enable_auto_assignment: true)

    # Admin is authorized to access inbox via account admin role, but is NOT in inbox.members
    expect(inbox.members).not_to include(admin)

    post path, headers: admin.create_new_auth_token, params: params, as: :json
    expect(response).to have_http_status(:created)
    conversation = account.conversations.last
    expect(conversation).to be_open
    expect(conversation.assignee).to eq(admin)
  end

  it 'resolves an existing contact with 8-digit mobile when operator submits 9-digit format' do
    existing_contact = create(:contact, account: account, name: 'Cliente Oito Digitos', phone_number: '+558588887777')
    contact_inbox = create(:contact_inbox, contact: existing_contact, inbox: inbox, source_id: '558588887777')

    expect do
      post path, headers: agent.create_new_auth_token, params: params.merge(phone_number: '+5585988887777', name: 'Nome Novo Ignorado'), as: :json
    end.not_to change(account.contacts, :count)

    expect(response).to have_http_status(:created)
    conversation = account.conversations.last
    expect(conversation.contact).to eq(existing_contact)
    expect(conversation.contact_inbox).to eq(contact_inbox)
    expect(existing_contact.reload.name).to eq('Cliente Oito Digitos')
  end

  it 'resolves an existing contact with 9-digit mobile when operator submits 8-digit format' do
    existing_contact = create(:contact, account: account, name: 'Cliente Nove Digitos', phone_number: '+5585988887777')
    contact_inbox = create(:contact_inbox, contact: existing_contact, inbox: inbox, source_id: '5585988887777')

    expect do
      post path, headers: agent.create_new_auth_token, params: params.merge(phone_number: '+558588887777', name: 'Nome Novo Ignorado'), as: :json
    end.not_to change(account.contacts, :count)

    expect(response).to have_http_status(:created)
    conversation = account.conversations.last
    expect(conversation.contact).to eq(existing_contact)
    expect(conversation.contact_inbox).to eq(contact_inbox)
    expect(existing_contact.reload.name).to eq('Cliente Nove Digitos')
  end

  it 'does not treat 8-digit landlines as equivalent to mobile numbers' do
    landline_contact = create(:contact, account: account, name: 'Telefone Fixo', phone_number: '+558532221111')
    create(:contact_inbox, contact: landline_contact, inbox: inbox, source_id: '558532221111')

    # Submitting a mobile number with the same suffix must not match the landline contact
    expect do
      post path, headers: agent.create_new_auth_token, params: params.merge(phone_number: '+5585932221111', name: 'Cliente Celular'), as: :json
    end.to change(account.contacts, :count).by(1)

    expect(response).to have_http_status(:created)
    conversation = account.conversations.last
    expect(conversation.contact).not_to eq(landline_contact)
    expect(conversation.contact.phone_number).to eq('+5585932221111')
  end

  it 'creates conversation as resolved when the contact is blocked' do
    blocked_contact = create(:contact, account: account, name: 'Contato Bloqueado', phone_number: params[:phone_number], blocked: true)

    post path, headers: agent.create_new_auth_token, params: params, as: :json
    expect(response).to have_http_status(:created)
    conversation = account.conversations.last
    expect(conversation).to be_resolved
    expect(conversation.contact).to eq(blocked_contact)
  end

  it 'tags the conversation with csat_enviado, ensures the account label, and updates inbox survey_rules preserving existing values' do
    inbox.update!(csat_config: inbox.csat_config.merge('survey_rules' => { 'operator' => 'does_not_contain', 'values' => ['MKT - JULIA'] }))

    post path, headers: agent.create_new_auth_token, params: params, as: :json
    expect(response).to have_http_status(:created)

    conversation = account.conversations.last
    expect(conversation.label_list).to include('csat_enviado')

    label = account.labels.find_by(title: 'csat_enviado')
    expect(label).to be_present
    expect(label.show_on_sidebar).to be(true)

    survey_rules = inbox.reload.csat_config['survey_rules']
    expect(survey_rules['operator']).to eq('does_not_contain')
    expect(survey_rules['values']).to contain_exactly('MKT - JULIA', 'csat_enviado')
  end

  it 'converts empty UI survey rules into does_not_contain with csat_enviado' do
    inbox.update!(csat_config: inbox.csat_config.merge('survey_rules' => { 'operator' => 'contains', 'values' => [] }))

    post path, headers: agent.create_new_auth_token, params: params, as: :json
    expect(response).to have_http_status(:created)

    conversation = account.conversations.last
    expect(conversation.label_list).to include('csat_enviado')

    survey_rules = inbox.reload.csat_config['survey_rules']
    expect(survey_rules['operator']).to eq('does_not_contain')
    expect(survey_rules['values']).to eq(['csat_enviado'])
  end

  it 'does not apply the csat_enviado tag when send_csat is false' do
    payload = params.merge(send_csat: false, content: 'Template',
                           template_params: { name: template['name'], language: 'pt_BR', processed_params: {} })
    post path, headers: agent.create_new_auth_token, params: payload, as: :json
    expect(response).to have_http_status(:created)

    conversation = account.conversations.last
    expect(conversation.label_list).not_to include('csat_enviado')
  end

  it 'prevents duplicate CSAT survey sending when the quick CSAT conversation is later resolved' do
    inbox.update!(csat_config: inbox.csat_config.merge('survey_rules' => { 'operator' => 'contains', 'values' => ['csat_enviado'] }))
    post path, headers: agent.create_new_auth_token, params: params, as: :json
    conversation = account.conversations.last

    expect(conversation.messages.input_csat.count).to eq(1)

    # Resolving the conversation must not trigger another survey or activity message
    conversation.update!(status: :resolved)
    expect do
      CsatSurveyService.new(conversation: conversation).perform
    end.not_to change(conversation.messages, :count)
  end
end
