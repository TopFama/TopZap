require 'rails_helper'

RSpec.describe 'Quick WhatsApp conversations API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', message_templates: [template]) }
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
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config).and_return(true)
    create(:inbox_member, user: agent, inbox: inbox)
  end

  it 'creates the contact, digit-only source and an open assigned conversation with native CSAT' do
    expect do
      post path, headers: agent.create_new_auth_token, params: params, as: :json
    end.to change(account.contacts, :count).by(1)
    expect(response).to have_http_status(:created)
    conversation = account.conversations.last
    expect(conversation).to be_open
    expect(conversation.assignee).to eq(agent)
    expect(conversation.contact.name).to eq('Cliente novo')
    expect(conversation.contact_inbox.source_id).to eq('5511999998888')
    message = conversation.messages.input_csat.last
    expect(message).to be_outgoing
    expect(message.content).to eq('Avalie seu atendimento')
    expect(message.additional_attributes.dig('template_params', 'processed_params', 'buttons', 0, 'parameter')).to eq(conversation.uuid)
    expect(JSON.parse(response.body)['id']).to eq(conversation.display_id)
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
end
