import {
  BRAZIL_PHONE_PREFIX,
  normalizeBrazilPhone,
  isValidBrazilPhone,
  hasApprovedCsatTemplate,
  approvedTemplates,
} from '../quickConversationHelper';

describe('quick WhatsApp conversation', () => {
  it('starts with the Brazilian country prefix', () => {
    expect(BRAZIL_PHONE_PREFIX).toBe('+55');
    expect(isValidBrazilPhone(BRAZIL_PHONE_PREFIX)).toBe(false);
  });

  it.each(['+5511999998888', '+551133334444', '+55 (11) 99999-8888'])(
    'accepts Brazilian numbers: %s',
    value => expect(isValidBrazilPhone(value)).toBe(true)
  );

  it.each([
    '11999998888',
    '+5411999998888',
    '+5501999998888',
    '+551199999888899',
    '+5511abc999998888',
    '',
    '+55',
  ])('rejects invalid numbers: %s', value =>
    expect(isValidBrazilPhone(value)).toBe(false)
  );

  it('normalizes formatting without adding the country code twice', () => {
    expect(normalizeBrazilPhone('+55 (11) 99999-8888')).toBe('+5511999998888');
  });

  it('requires approval and the exact configured name and language', () => {
    const inbox = {
      csat_config: {
        template: {
          name: 'customer_satisfaction_survey_92',
          language: 'pt_BR',
        },
      },
      message_templates: [
        {
          name: 'customer_satisfaction_survey_92',
          language: 'en',
          status: 'APPROVED',
        },
        {
          name: 'customer_satisfaction_survey_92',
          language: 'pt_BR',
          status: 'PENDING',
        },
      ],
    };
    expect(hasApprovedCsatTemplate(inbox)).toBe(false);
    inbox.message_templates[1].status = 'APPROVED';
    expect(hasApprovedCsatTemplate(inbox)).toBe(true);
    expect(approvedTemplates(inbox)).toHaveLength(2);
    expect(hasApprovedCsatTemplate(null)).toBe(false);
  });
});
