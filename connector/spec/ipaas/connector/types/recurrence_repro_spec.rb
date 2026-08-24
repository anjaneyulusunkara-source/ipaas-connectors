require 'spec_helper'

# Regression guard for Xurrent request #80388755.
#
# RecurrenceType.schema is a process-global singleton whose `after_update` mutates the shared Field
# flags (disabled/required) per frequency, and validation reads those flags live. Before the fix, one
# request resolving a monthly recurrence could leave `day_of_month` enabled on the shared singleton
# while another request validated a weekly recurrence, wrongly demanding `day_of_month`. The fix
# resolves each recurrence on a private copy, so resolving a different frequency can no longer
# contaminate this one.
describe 'Recurrence shared-singleton contamination (request #80388755)' do
  let(:recurrence_schema) { IPaaS::Connector::Types::RecurrenceType.schema }

  let(:config_schema) do
    IPaaS::Connector::Schema.new('config') do
      field :schedule, 'Schedule', :recurrence, required: true
    end
  end

  def weekly_mapping
    [{ field_id: :schedule, nested: [
      { field_id: :frequency, fixed: 'weekly' },
      { field_id: :time_zone, fixed: 'UTC' },
      { field_id: :interval, fixed: 1 },
      { field_id: :time_of_day, fixed: '09:00:00' },
      { field_id: :day, fixed: 'friday' },
    ], }]
  end

  def resolve_weekly
    IPaaS::Connector::Mapping::ResolvedMapping.new(Object.new, config_schema.fields, weekly_mapping).resolve
  end

  # Deterministic stand-in for a concurrent resolve of a different frequency on the shared singleton.
  def resolve_monthly_on_shared_singleton
    recurrence_schema.resolve(Object.new, [{ field_id: 'frequency', fixed: 'monthly' }])
  end

  it 'validates a well-formed weekly recurrence even after another frequency was resolved' do
    weekly = resolve_weekly
    resolve_monthly_on_shared_singleton
    weekly.valid?

    expect(weekly.full_error_messages).to eq('')
  end
end
