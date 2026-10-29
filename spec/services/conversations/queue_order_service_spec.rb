require 'rails_helper'

describe Conversations::QueueOrderService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let!(:oldest) { create(:conversation, account: account, inbox: inbox, status: :open, last_activity_at: 2.hours.ago) }
  let!(:newest) { create(:conversation, account: account, inbox: inbox, status: :open, last_activity_at: 1.hour.ago) }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
  end

  it 'allows picking the conversation with the oldest last activity' do
    expect { described_class.new(account: account, actor: agent, conversations: [oldest]).validate! }.not_to raise_error
  end

  it 'rejects skipping a conversation with an older last activity' do
    expect { described_class.new(account: account, actor: agent, conversations: [newest]).validate! }.to raise_error(
      CustomExceptions::ConversationAssignmentNotAllowed,
      "You can only assign the unassigned conversation with the oldest last activity. Assign conversation ##{oldest.display_id} first"
    )
  end

  it 'allows picking several conversations from the top of the queue' do
    expect { described_class.new(account: account, actor: agent, conversations: [oldest, newest]).validate! }.not_to raise_error
  end

  it 'ignores conversations in inboxes the agent cannot access' do
    oldest.update!(inbox: create(:inbox, account: account))

    expect { described_class.new(account: account, actor: agent, conversations: [newest]).validate! }.not_to raise_error
  end

  it 'does not apply to agent bots' do
    expect { described_class.new(account: account, actor: create(:agent_bot, account: account), conversations: [newest]).validate! }
      .not_to raise_error
  end

  it 'does not apply to administrators' do
    expect { described_class.new(account: account, actor: administrator, conversations: [newest]).validate! }.not_to raise_error
  end
end
