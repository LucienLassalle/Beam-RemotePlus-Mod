<!--
  In-game panel of the Beam-RemotePlus mod: pairing code, lock on new
  phones and the connected phones with their player number. Add it from the
  UI apps menu (it is optional: phones can connect as soon as the mod is
  installed).

  Built like the game's own 0.39 Vue apps: base components, --bng-* theme
  variables and the game's confirmation popup.
-->
<template>
  <div class="brp-root">
    <div class="brp-header">
      <span class="brp-title">{{ $t("beamRemotePlus.app.name") }}</span>
      <span v-if="state.code" class="brp-code" :title="$t('beamRemotePlus.app.code')">{{ state.code }}</span>
    </div>

    <div v-if="state.port && !state.listening" class="brp-alert">
      <BngIcon type="warning" color="var(--bng-add-red-400)" />
      <span>{{ $t("beamRemotePlus.app.portBusy") }}</span>
    </div>

    <BngSwitch :model-value="state.locked" @update:model-value="setLocked">
      <span class="brp-switch-label">
        <BngIcon :type="state.locked ? 'lockClosed' : 'lockOpened'" :color="state.locked ? 'var(--bng-orange-400)' : 'var(--bng-off-white)'" />
        {{ $t("beamRemotePlus.app.lock") }}
      </span>
    </BngSwitch>

    <div class="brp-section">
      <span>{{ $t("beamRemotePlus.app.phones") }}</span>
      <span class="brp-count">{{ phones.length }}</span>
    </div>
    <div class="brp-list">
      <div v-if="!phones.length" class="brp-empty">{{ $t("beamRemotePlus.app.noPhone") }}</div>
      <div v-for="phone in phones" :key="phone.ip" class="brp-phone">
        <BngIcon class="brp-phone-icon" :type="phone.display ? 'screen' : 'smartphone1'" />
        <div class="brp-phone-text">
          <span class="brp-phone-name">{{ phone.device }}</span>
          <span class="brp-phone-role">
            {{ phone.display ? $t("beamRemotePlus.app.secondScreen") + " · " : "" }}{{ $t("beamRemotePlus.app.player") }} {{ playerNumber(phone) }}
          </span>
        </div>
        <BngButton
          class="brp-kick"
          :accent="ACCENTS.ghost"
          icon="xmark"
          :title="$t('beamRemotePlus.app.kick')"
          @click="confirmKick(phone)" />
      </div>
    </div>

    <div class="brp-footer">
      <BngSwitch :model-value="state.debug" @update:model-value="setDebug">
        {{ $t("beamRemotePlus.app.debug") }}
      </BngSwitch>
      <span class="brp-version">v{{ state.version }}</span>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted } from "vue"
import { useBridge } from "@/bridge"
import { useEvents } from "@/services/events"
import { openConfirmation, confirmCancelButtons } from "@/services/popup"
import { $translate } from "@/services/translation"
import { BngButton, BngSwitch, BngIcon, ACCENTS } from "@/common/components/base"

const { api } = useBridge()
const events = useEvents()

const state = ref({ listening: false, locked: false, debug: false, phones: [], version: "" })
const phones = computed(() => state.value.phones || [])

// The extension may not be loaded yet (or anymore): never raise a Lua error.
// Arguments are booleans and IP strings, written the same in JSON and Lua.
function callMod(fn, ...args) {
  api.engineLua(`if extensions.beamRemotePlus_main then extensions.beamRemotePlus_main.${fn}(${args.map(a => JSON.stringify(a)).join(",")}) end`)
}

const setLocked = value => callMod("setLocked", !!value)
const setDebug = value => callMod("setDebug", !!value)

// BeamNG players are 0-based; a phone is unassigned for a moment after pairing.
const playerNumber = phone => (phone.player === undefined || phone.player === null ? "?" : phone.player + 1)

async function confirmKick(phone) {
  const kick = await openConfirmation(
    $translate.instant("beamRemotePlus.app.kickTitle", { device: phone.device }),
    $translate.instant("beamRemotePlus.app.kickMessage"),
    confirmCancelButtons({ confirmLabel: $translate.instant("beamRemotePlus.app.kickConfirm"), destructive: true })
  )
  if (kick) callMod("kick", phone.ip)
}

onMounted(() => {
  events.on("BeamRemotePlusState", newState => {
    if (newState) state.value = { ...newState, phones: newState.phones || [] }
  })
  callMod("requestState")
})
</script>

<style scoped lang="scss">
.brp-root {
  width: 100%;
  height: 100%;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
  padding: 0.5rem;
  overflow: hidden;
  color: var(--bng-off-white);
  background-color: rgba(var(--bng-off-black-rgb), 0.6);
  border-radius: var(--bng-corners-2);
  font-family: var(--fnt-defs);
  font-size: 0.875rem;
}

.brp-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  padding-bottom: 0.25rem;
  border-bottom: 1px solid rgba(var(--bng-off-white-rgb), 0.15);
}

.brp-title {
  font-weight: 700;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.brp-code {
  padding: 0.125rem 0.5rem;
  border-radius: var(--bng-corners-1);
  background-color: var(--bng-orange-b400);
  color: var(--bng-off-black);
  font-family: var(--fnt-mono);
  font-weight: 700;
  letter-spacing: 0.1em;
}

.brp-alert {
  display: flex;
  align-items: center;
  gap: 0.375rem;
  padding: 0.25rem 0.5rem;
  border-radius: var(--bng-corners-1);
  background-color: rgba(var(--bng-off-black-rgb), 0.5);
  color: var(--bng-add-red-400);
}

.brp-switch-label {
  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
}

.brp-section {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-top: 0.25rem;
  color: var(--bng-cool-gray-300);
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.brp-count {
  min-width: 1.25rem;
  padding: 0 0.375rem;
  border-radius: var(--bng-corners-1);
  background-color: rgba(var(--bng-off-white-rgb), 0.1);
  text-align: center;
}

.brp-list {
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

.brp-empty {
  padding: 0.5rem;
  color: var(--bng-cool-gray-300);
  font-style: italic;
  text-align: center;
}

.brp-phone {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.25rem 0.25rem 0.25rem 0.5rem;
  border-radius: var(--bng-corners-1);
  background-color: rgba(var(--bng-off-white-rgb), 0.06);
}

.brp-phone-icon {
  flex: 0 0 auto;
  font-size: 1.25rem;
}

.brp-phone-text {
  flex: 1 1 auto;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.brp-phone-name {
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.brp-phone-role {
  color: var(--bng-orange-400);
  font-size: 0.75rem;
}

.brp-kick {
  flex: 0 0 auto;
  --bng-button-min-width: 2em;
  --bng-icon-color: var(--bng-add-red-500);
  margin: 0;
}

.brp-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem;
  padding-top: 0.25rem;
  border-top: 1px solid rgba(var(--bng-off-white-rgb), 0.15);
  font-size: 0.75rem;
}

.brp-version {
  color: var(--bng-cool-gray-300);
  font-family: var(--fnt-mono);
  white-space: nowrap;
}
</style>
