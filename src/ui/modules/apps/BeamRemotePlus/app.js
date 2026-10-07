// In-game panel of the Beam-RemotePlus mod: enable switch, pairing code and
// connected phones. Add it from the UI apps menu (it is optional: phones can
// connect as soon as the mod is enabled, which is the default).
angular.module('beamng.apps')
.directive('beamRemotePlus', [function () {
  return {
    template: `
      <div class="brp-root">
        <label class="brp-row brp-switch">
          <input type="checkbox" ng-model="state.enabled" ng-change="setEnabled(state.enabled)">
          <span>{{ 'beamRemotePlus.app.enable' | translate }}</span>
        </label>
        <div class="brp-row" ng-if="state.enabled && !state.listening" style="color:#ff8a65">
          {{ 'beamRemotePlus.app.portBusy' | translate }}
        </div>
        <div class="brp-row" ng-if="state.code">
          {{ 'beamRemotePlus.app.code' | translate }}: <b class="brp-code">{{ state.code }}</b>
        </div>
        <div class="brp-row brp-title">{{ 'beamRemotePlus.app.phones' | translate }}</div>
        <div class="brp-row brp-dim" ng-if="!state.phones.length">{{ 'beamRemotePlus.app.noPhone' | translate }}</div>
        <div class="brp-row" ng-repeat="p in state.phones">
          {{ p.device }} &middot; {{ 'beamRemotePlus.app.player' | translate }} {{ p.player === undefined || p.player === null ? '?' : p.player + 1 }}
        </div>
        <label class="brp-row brp-switch brp-dim">
          <input type="checkbox" ng-model="state.debug" ng-change="setDebug(state.debug)">
          <span>{{ 'beamRemotePlus.app.debug' | translate }}</span>
        </label>
        <div class="brp-version brp-dim">v{{ state.version }}</div>
      </div>`,
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element) {
      element.css({ background: 'rgba(0,0,0,0.55)', color: '#fff', padding: '8px', 'font-size': '13px',
        'box-sizing': 'border-box', height: '100%', overflow: 'auto', 'border-radius': '4px' })
      scope.state = { enabled: true, listening: false, phones: [], debug: false }

      scope.$on('BeamRemotePlusState', function (event, state) {
        scope.$evalAsync(function () {
          state.phones = state.phones || []
          scope.state = state
        })
      })

      scope.setEnabled = function (enabled) {
        bngApi.engineLua('if extensions.beamRemotePlus_main then extensions.beamRemotePlus_main.setEnabled(' + (enabled ? 'true' : 'false') + ') end')
      }
      scope.setDebug = function (enabled) {
        bngApi.engineLua('if extensions.beamRemotePlus_main then extensions.beamRemotePlus_main.setDebug(' + (enabled ? 'true' : 'false') + ') end')
      }

      bngApi.engineLua('if extensions.beamRemotePlus_main then extensions.beamRemotePlus_main.requestState() end')
    }
  }
}])
