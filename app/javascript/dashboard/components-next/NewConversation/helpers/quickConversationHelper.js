export const BRAZIL_PHONE_PREFIX = '+55';

export const normalizeBrazilPhone = value => {
  if (!/^\+?[0-9()\s-]+$/.test(value)) return '';
  return `+${value.replace(/\D/g, '')}`;
};

export const isValidBrazilPhone = value =>
  /^\+55[1-9][0-9]{9,10}$/.test(normalizeBrazilPhone(value));

export const approvedTemplates = inbox =>
  (inbox?.message_templates || []).filter(item => item.status === 'APPROVED');

export const hasApprovedCsatTemplate = inbox => {
  const template = inbox?.csat_config?.template;
  return approvedTemplates(inbox).some(
    item => item.name === template?.name && item.language === template?.language
  );
};
