require 'rails_helper'

RSpec.describe CsatSurveyService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud') }
  let(:inbox) do
    create(:inbox, account: account, channel: channel,
                   csat_config: { template: { name: 'customer_satisfaction_survey_95', language: 'pt_BR' }, message: 'Avalie' })
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :open) }

  before do
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config).and_return(true)
  end

  it 'sends the configured template through the native reply job and stores the source id' do
    channel.update!(message_templates: [{ name: 'customer_satisfaction_survey_95', language: 'pt_BR', status: 'APPROVED', components: [] }])
    message = described_class.new(conversation: conversation).build_whatsapp_template_survey
    message.save!
    provider = instance_double(Whatsapp::Providers::WhatsappCloudService)
    allow_any_instance_of(Channel::Whatsapp).to receive(:provider_service).and_return(provider)
    expect(provider).to receive(:send_template).with(
      conversation.contact_inbox.source_id,
      hash_including(name: 'customer_satisfaction_survey_95', lang_code: 'pt_BR', parameters: [
                       { type: 'button', sub_type: 'url', index: 0, parameters: [{ type: 'text', text: conversation.uuid }] }
                     ]), message
    ).and_return('wamid.synthetic')
    SendReplyJob.perform_now(message.id)
    expect(message.reload.source_id).to eq('wamid.synthetic')
    # Replaying the job must not send the same successful survey again.
    SendReplyJob.perform_now(message.id)
  end

  it 'blocks resolution CSAT surveys when the conversation has the csat_enviado label' do
    conversation.update!(status: :resolved)
    conversation.add_labels([described_class::QUICK_CSAT_LABEL])
    # Even if inbox survey rules would otherwise allow (e.g. contains operator)
    inbox.update!(csat_config: inbox.csat_config.merge('survey_rules' => { 'operator' => 'contains', 'values' => [described_class::QUICK_CSAT_LABEL] }))

    provider = instance_double(Whatsapp::Providers::WhatsappCloudService)
    allow_any_instance_of(Channel::Whatsapp).to receive(:provider_service).and_return(provider)
    expect(provider).not_to receive(:send_template)

    expect do
      described_class.new(conversation: conversation).perform
    end.not_to change(conversation.messages, :count)
  end
end
