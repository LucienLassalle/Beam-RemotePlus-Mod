<!--
  In-game panel of the Beam-RemotePlus mod: pairing code, lock on new
  phones, the connected phones with their player number and, in a second
  tab, the optional mods it works with. Add it from the
  UI apps menu (it is optional: phones can connect as soon as the mod is
  installed).

  Built like the game's own 0.39 Vue apps: base components, --bng-* theme
  variables and the game's confirmation popup.
-->
<template>
  <div class="brp-root">
    <div class="brp-header">
      <span class="brp-title">{{ $t("beamRemotePlus.app.name") }}</span>
      <button
        v-if="state.code"
        type="button"
        class="brp-code"
        :class="{ 'brp-code-shown': codeShown }"
        :title="$t(codeShown ? 'beamRemotePlus.app.codeHide' : 'beamRemotePlus.app.codeShow')"
        @click="codeShown = !codeShown">
        <BngIcon :type="codeShown ? 'eyeSolidOpened' : 'eyeSolidClosed'" color="var(--bng-off-black)" />
        <span class="brp-code-digits">{{ codeShown ? state.code : maskedCode }}</span>
      </button>
      <button
        v-if="state.pairingUri"
        type="button"
        class="brp-code brp-qr-toggle"
        :class="{ 'brp-code-shown': qrShown }"
        :title="$t(qrShown ? 'beamRemotePlus.app.qrHide' : 'beamRemotePlus.app.qrShow')"
        @click="qrShown = !qrShown">
        QR
      </button>
    </div>

    <div v-if="qrShown && state.pairingUri" class="brp-qr">
      <div ref="qrEl" class="brp-qr-image" />
      <span v-if="qrFailed" class="brp-qr-fallback">{{ state.code }}</span>
      <span class="brp-hint">{{ $t("beamRemotePlus.app.qrHint") }}</span>
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

    <div class="brp-tabs">
      <button type="button" class="brp-tab" :class="{ 'brp-tab-on': !showMods }" @click="showMods = false">
        <span>{{ $t("beamRemotePlus.app.phones") }}</span>
        <span class="brp-count">{{ activeCount }}</span>
      </button>
      <button type="button" class="brp-tab" :class="{ 'brp-tab-on': showMods }" @click="showMods = true">
        <span>{{ $t("beamRemotePlus.app.optionalMods") }}</span>
        <span class="brp-count">{{ enabledCount }}/{{ optionalMods.length }}</span>
      </button>
    </div>

    <template v-if="showMods">
      <div class="brp-list">
        <div class="brp-hint">{{ $t("beamRemotePlus.app.optionalModsHint") }}</div>
        <div v-for="mod in optionalMods" :key="mod.id" class="brp-mod" :class="'brp-mod-' + mod.state">
          <div class="brp-phone-text">
            <span class="brp-phone-name">{{ $t(modText(mod).name) }}</span>
            <span v-if="modText(mod).features" class="brp-mod-features">{{ $t(modText(mod).features) }}</span>
          </div>
          <span class="brp-mod-status">
            <BngIcon v-if="mod.state === 'enabled'" type="checkmark" color="var(--bng-add-green-400)" />
            {{ $t(STATE_TEXTS[mod.state] || STATE_TEXTS.missing) }}
          </span>
        </div>
      </div>
    </template>

    <template v-else>
      <div class="brp-list">
        <div v-if="!phones.length" class="brp-empty">{{ $t("beamRemotePlus.app.noPhone") }}</div>
        <div v-for="phone in phones" :key="phone.ip" class="brp-phone" :class="'brp-phone-' + status(phone)">
          <BngIcon class="brp-phone-icon" :type="phone.display ? 'screen' : 'smartphone1'" />
          <div class="brp-phone-text">
            <span class="brp-phone-name">{{ phone.device }}</span>
            <span class="brp-phone-status">
              <span class="brp-status-dot" />
              {{ $t(STATUS_TEXTS[status(phone)]) }}
            </span>
            <span class="brp-phone-role">
              {{ phone.display ? $t("beamRemotePlus.app.secondScreen") + " · " : "" }}{{ $t("beamRemotePlus.app.player") }} {{ playerNumber(phone) }}{{ phone.appVersion ? " · v" + phone.appVersion : "" }}
            </span>
            <span v-if="phone.update" class="brp-phone-update">
              <BngIcon type="warning" color="var(--bng-orange-400)" />
              {{ updateText(phone) }}
            </span>
          </div>
          <BngButton
            v-if="status(phone) !== 'disconnected'"
            class="brp-kick"
            :accent="ACCENTS.ghost"
            icon="xmark"
            :title="$t('beamRemotePlus.app.kick')"
            @click="confirmKick(phone)" />
        </div>
      </div>
    </template>

    <div class="brp-footer">
      <BngSwitch :model-value="state.debug" @update:model-value="setDebug">
        {{ $t("beamRemotePlus.app.debug") }}
      </BngSwitch>
      <span class="brp-version">v{{ state.version }}</span>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted, watch, nextTick } from "vue"
import { useBridge } from "@/bridge"
import { useEvents } from "@/services/events"
import { openConfirmation, confirmCancelButtons } from "@/services/popup"
import { $translate } from "@/services/translation"
import { BngButton, BngSwitch, BngIcon, ACCENTS } from "@/common/components/base"

const { api } = useBridge()
const events = useEvents()

const state = ref({ listening: false, locked: false, debug: false, phones: [], version: "" })
// An empty Lua table reaches the UI as {} instead of []: always a list here.
const asList = value => (Array.isArray(value) ? value : Object.values(value || {}))
const phones = computed(() => asList(state.value.phones))

// Live status of each phone (server.lua): a disconnected phone stays listed,
// greyed out, for 30 seconds. Older Lua sides send no status.
const status = phone => phone.status || "connected"
const STATUS_TEXTS = {
  connected: "beamRemotePlus.app.statusConnected",
  signalLost: "beamRemotePlus.app.statusSignalLost",
  disconnected: "beamRemotePlus.app.statusDisconnected",
}
const activeCount = computed(() => phones.value.filter(phone => status(phone) !== "disconnected").length)

// Optional mods the mod works with and whether each one is enabled,
// installed but disabled, or missing (optionalMods.lua), in their own tab
// next to the phones.
const showMods = ref(false)
const optionalMods = computed(() => asList(state.value.optionalMods))
const enabledCount = computed(() => optionalMods.value.filter(mod => mod.state === "enabled").length)
const STATE_TEXTS = {
  enabled: "beamRemotePlus.app.modEnabled",
  disabled: "beamRemotePlus.app.modDisabled",
  missing: "beamRemotePlus.app.modMissing",
}
const MOD_TEXTS = {
  tyreThermals: { name: "beamRemotePlus.mods.tyreThermals", features: "beamRemotePlus.mods.tyreThermalsFeatures" },
  cf26: { name: "beamRemotePlus.mods.cf26", features: "beamRemotePlus.mods.cf26Features" },
  f4: { name: "beamRemotePlus.mods.f4", features: "beamRemotePlus.mods.f4Features" },
  fr17: { name: "beamRemotePlus.mods.fr17", features: "beamRemotePlus.mods.fr17Features" },
}
// A newer Lua side may know mods this panel does not: shown by their id.
const modText = mod => MOD_TEXTS[mod.id] || { name: mod.id, features: "" }

// The pairing code lets anyone on the network drive: hidden until clicked
// (streams, screenshots), hidden again on a second click.
const codeShown = ref(false)
const maskedCode = computed(() => Array.from(String(state.value.code || "")).map(() => "X").join(" "))

// Pairing QR code (code + PC address, see protocol.buildPairingUri): hidden
// like the code, drawn with the QRCode library the game's UI already loads.
const qrShown = ref(false)
const qrEl = ref(null)
const qrFailed = ref(false)
const QR_SIZE = 160

async function drawQr() {
  await nextTick()
  const el = qrEl.value
  if (!el) return
  el.innerHTML = ""
  const QRCodeLib = window.QRCode
  qrFailed.value = typeof QRCodeLib !== "function"
  if (qrFailed.value) return
  try {
    new QRCodeLib(el, { text: state.value.pairingUri, width: QR_SIZE, height: QR_SIZE, correctLevel: QRCodeLib.CorrectLevel.M })
  } catch {
    qrFailed.value = true
  }
}

watch([qrShown, () => state.value.pairingUri], ([shown, uri]) => {
  if (shown && uri) drawQr()
})

// The extension may not be loaded yet (or anymore): never raise a Lua error.
// Arguments are booleans and IP strings, written the same in JSON and Lua.
function callMod(fn, ...args) {
  api.engineLua(`if extensions.beamRemotePlus_main then extensions.beamRemotePlus_main.${fn}(${args.map(a => JSON.stringify(a)).join(",")}) end`)
}

const setLocked = value => callMod("setLocked", !!value)
const setDebug = value => callMod("setDebug", !!value)

// BeamNG players are 0-based; a phone is unassigned for a moment after pairing.
const playerNumber = phone => (phone.player === undefined || phone.player === null ? "?" : phone.player + 1)

// The mod compares its version with the app of each phone (server.lua):
// update is "app" or "mod", whichever is older.
const updateText = phone =>
  $translate.instant(phone.update === "mod" ? "beamRemotePlus.app.updateMod" : "beamRemotePlus.app.updateApp", { version: phone.appVersion })

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
    if (newState) state.value = newState
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
  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
  flex: 0 0 auto;
  padding: 0.125rem 0.5rem;
  border: 0;
  border-radius: var(--bng-corners-1);
  background-color: var(--bng-orange-b400);
  color: var(--bng-off-black);
  font-family: var(--fnt-mono);
  font-size: inherit;
  font-weight: 700;
  letter-spacing: 0.1em;
  cursor: pointer;
  opacity: 0.85;
  transition: opacity 0.15s, box-shadow 0.15s;

  // Hover / keyboard focus: tells the player the chip is a button.
  &:hover,
  &:focus-visible {
    opacity: 1;
    box-shadow: 0 0 0 2px var(--bng-off-white);
    outline: none;
  }

  &.brp-code-shown {
    opacity: 1;
  }
}

.brp-code-digits {
  white-space: nowrap;
}

.brp-qr-toggle {
  font-family: inherit;
  letter-spacing: 0.05em;
}

.brp-qr {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.25rem;
  padding: 0.25rem 0;
}

.brp-qr-image {
  padding: 0.5rem;
  border-radius: var(--bng-corners-1);
  background-color: #fff;
  line-height: 0;
}

.brp-qr-fallback {
  font-family: var(--fnt-mono);
  font-size: 1.25rem;
  font-weight: 700;
  letter-spacing: 0.2em;
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

.brp-tabs {
  display: flex;
  gap: 0.25rem;
  margin-top: 0.25rem;
  border-bottom: 1px solid rgba(var(--bng-off-white-rgb), 0.15);
}

.brp-tab {
  display: inline-flex;
  align-items: center;
  gap: 0.375rem;
  padding: 0.25rem 0.5rem;
  border: 0;
  border-bottom: 2px solid transparent;
  background: none;
  color: var(--bng-cool-gray-300);
  font-family: inherit;
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  cursor: pointer;

  &:hover,
  &:focus-visible {
    color: var(--bng-off-white);
    outline: none;
  }

  &.brp-tab-on {
    color: var(--bng-off-white);
    border-bottom-color: var(--bng-orange-400);
  }
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

.brp-phone-status {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  font-size: 0.75rem;
  color: var(--bng-add-green-400);
}

.brp-status-dot {
  width: 0.5rem;
  height: 0.5rem;
  border-radius: 50%;
  background-color: currentColor;
}

.brp-phone-signalLost .brp-phone-status {
  color: var(--bng-orange-400);
}

.brp-phone-disconnected {
  opacity: 0.55;

  .brp-phone-status {
    color: var(--bng-cool-gray-300);
  }
}

.brp-phone-role {
  color: var(--bng-orange-400);
  font-size: 0.75rem;
}

.brp-phone-update {
  display: flex;
  align-items: center;
  gap: 0.25rem;
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

.brp-hint {
  padding: 0 0.25rem 0.25rem;
  color: var(--bng-cool-gray-300);
  font-size: 0.75rem;
}

.brp-mod {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.25rem 0.5rem;
  border-radius: var(--bng-corners-1);
  background-color: rgba(var(--bng-off-white-rgb), 0.06);

  &.brp-mod-disabled .brp-mod-status {
    color: var(--bng-orange-400);
  }

  &.brp-mod-missing {
    opacity: 0.6;
  }
}

.brp-mod-features {
  color: var(--bng-cool-gray-300);
  font-size: 0.75rem;
}

.brp-mod-status {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  flex: 0 0 auto;
  font-size: 0.75rem;
  white-space: nowrap;
}

.brp-version {
  color: var(--bng-cool-gray-300);
  font-family: var(--fnt-mono);
  white-space: nowrap;
}
</style>
