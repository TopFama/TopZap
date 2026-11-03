<script setup>
/* global axios */
import { computed, ref, watch } from 'vue';
import { useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import WhatsappTemplate from './components/WhatsappTemplate.vue';
import {
  BRAZIL_PHONE_PREFIX,
  normalizeBrazilPhone,
  isValidBrazilPhone,
  approvedTemplates,
  hasApprovedCsatTemplate,
} from './helpers/quickConversationHelper';

const { t } = useI18n();
const router = useRouter();
const dialog = ref(null);
const allInboxes = useMapGetter('inboxes/getInboxes');
const accountId = useMapGetter('getCurrentAccountId');
const inboxes = computed(() =>
  allInboxes.value.filter(
    inbox =>
      inbox.channel_type === 'Channel::Whatsapp' &&
      inbox.provider === 'whatsapp_cloud'
  )
);
const inboxId = ref('');
const phone = ref(BRAZIL_PHONE_PREFIX);
const name = ref('');
const sendCsat = ref(true);
const templateName = ref('');
const busy = ref(false);
const error = ref('');
const inbox = computed(() =>
  inboxes.value.find(item => item.id === Number(inboxId.value))
);
const csatAvailable = computed(() => hasApprovedCsatTemplate(inbox.value));
const templates = computed(() => approvedTemplates(inbox.value));
const selectedTemplate = computed(() =>
  templates.value.find(
    item => `${item.name}:${item.language}` === templateName.value
  )
);
const valid = computed(
  () => inbox.value && name.value.trim() && isValidBrazilPhone(phone.value)
);
watch(inboxId, () => {
  templateName.value = '';
  sendCsat.value = csatAvailable.value;
  error.value = '';
});

const open = () => {
  inboxId.value = inboxes.value[0]?.id || '';
  phone.value = BRAZIL_PHONE_PREFIX;
  name.value = '';
  sendCsat.value = csatAvailable.value;
  templateName.value = '';
  error.value = '';
  dialog.value.open();
};
const create = async (templatePayload = null) => {
  if (!valid.value || busy.value || (sendCsat.value && !csatAvailable.value))
    return;
  if (!sendCsat.value && !templatePayload?.templateParams) return;
  busy.value = true;
  error.value = '';
  try {
    const { data } = await axios.post(
      `/api/v1/accounts/${accountId.value}/topzap/quick_conversations`,
      {
        inbox_id: inboxId.value,
        phone_number: normalizeBrazilPhone(phone.value),
        name: name.value.trim(),
        send_csat: sendCsat.value,
        ...(sendCsat.value
          ? {}
          : {
              content: templatePayload.message,
              template_params: templatePayload.templateParams,
            }),
      }
    );
    dialog.value.close();
    useAlert(t('QUICK_CONVERSATION.QUEUED'));
    router.push(`/app/accounts/${accountId.value}/conversations/${data.id}`);
  } catch (exception) {
    error.value =
      exception.response?.data?.error ||
      exception.response?.data?.message ||
      t('QUICK_CONVERSATION.ERROR');
  } finally {
    busy.value = false;
  }
};
</script>

<template>
  <Button
    icon="i-lucide-message-circle-plus"
    size="sm"
    color="slate"
    :aria-label="t('QUICK_CONVERSATION.TITLE')"
    :title="t('QUICK_CONVERSATION.TITLE')"
    @click="open"
  />
  <Dialog
    ref="dialog"
    :title="t('QUICK_CONVERSATION.TITLE')"
    :description="t('QUICK_CONVERSATION.DESCRIPTION')"
    :confirm-button-label="t('QUICK_CONVERSATION.SEND')"
    :disable-confirm-button="!valid || !csatAvailable || busy"
    :show-confirm-button="sendCsat"
    :is-loading="busy"
    @confirm="create()"
  >
    <div class="flex flex-col gap-4">
      <label class="text-sm text-n-slate-12">
        {{ t('QUICK_CONVERSATION.INBOX') }}
        <select v-model="inboxId" :disabled="busy" class="w-full">
          <option v-for="item in inboxes" :key="item.id" :value="item.id">
            {{ item.name }}
          </option>
        </select>
      </label>
      <p v-if="!inboxes.length" class="text-sm text-n-slate-11">
        {{ t('QUICK_CONVERSATION.NO_INBOX') }}
      </p>
      <label class="text-sm text-n-slate-12">
        {{ t('QUICK_CONVERSATION.PHONE') }}
        <input
          v-model="phone"
          type="tel"
          autocomplete="tel"
          :disabled="busy"
          :aria-invalid="!isValidBrazilPhone(phone)"
        />
      </label>
      <p
        v-if="phone !== BRAZIL_PHONE_PREFIX && !isValidBrazilPhone(phone)"
        class="text-sm text-n-ruby-11"
      >
        {{ t('QUICK_CONVERSATION.INVALID_PHONE') }}
      </p>
      <label class="text-sm text-n-slate-12">
        {{ t('QUICK_CONVERSATION.NAME') }}
        <input
          v-model="name"
          type="text"
          autocomplete="name"
          :disabled="busy"
        />
      </label>
      <label class="flex items-center gap-2 text-sm text-n-slate-12">
        <input
          v-model="sendCsat"
          type="checkbox"
          :disabled="!csatAvailable || busy"
        />
        {{ t('QUICK_CONVERSATION.CSAT') }}
      </label>
      <p v-if="!csatAvailable" class="text-sm text-n-amber-11">
        {{ t('QUICK_CONVERSATION.NO_CSAT') }}
      </p>
      <template v-if="!sendCsat">
        <label class="text-sm text-n-slate-12">
          {{ t('QUICK_CONVERSATION.TEMPLATE') }}
          <select v-model="templateName" :disabled="busy" class="w-full">
            <option value="" disabled>
              {{ t('QUICK_CONVERSATION.TEMPLATE') }}
            </option>
            <option
              v-for="item in templates"
              :key="`${item.name}:${item.language}`"
              :value="`${item.name}:${item.language}`"
            >
              {{ `${item.name} (${item.language})` }}
            </option>
          </select>
        </label>
        <div
          v-if="valid && selectedTemplate"
          :class="{ 'pointer-events-none opacity-50': busy }"
          class="max-w-full overflow-x-auto"
        >
          <WhatsappTemplate
            :key="templateName"
            :template="selectedTemplate"
            @send-message="create"
            @back="templateName = ''"
          />
        </div>
      </template>
      <p v-if="error" role="alert" class="text-sm text-n-ruby-11">
        {{ error }}
      </p>
    </div>
  </Dialog>
</template>
