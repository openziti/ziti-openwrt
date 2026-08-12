// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require zitibuild';

var DOC_URL = 'https://openziti.github.io/ziti-openwrt/';
var UI_BUILD = zitibuild.BUILD;

var callGet = rpc.declare({
	object: 'ziti', method: 'get_tunnel_mode', expect: { }
});
var callList = rpc.declare({
	object: 'ziti', method: 'list_identities', expect: { }
});
var callSet = rpc.declare({
	object: 'ziti', method: 'set_tunnel_mode',
	params: [ 'mode', 'full_identity', 'split_identity' ], expect: { }
});

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function () {
		return Promise.all([
			callGet().catch(function () { return {}; }),
			callList().catch(function () { return { identities: [] }; })
		]);
	},

	render: function (data) {
		var cur  = data[0] || {};
		var ids  = (data[1] && data[1].identities) || [];
		var mode = cur.mode || 'split';
		var haveIds = ids.length > 0;
		var activeNames = ids.filter(function (i) { return i.enabled; }).map(function (i) { return i.name; });

		function idSelect(current) {
			var sel = E('select', { 'class': 'cbi-input-select', 'style': 'min-width:16em' },
				[ E('option', { 'value': '' }, _('-- none --')) ]);
			ids.forEach(function (it) {
				sel.appendChild(E('option', { 'value': it.name }, it.name));
			});
			sel.value = current || '';
			return sel;
		}
		var fullSel  = idSelect(cur.full_identity);
		var splitSel = idSelect(cur.split_identity);

		function apply(newMode) {
			var full  = fullSel.value  || '';
			var split = splitSel.value || '';
			if (newMode == 'full' && !full)
				return ui.addNotification(null, E('p', {}, _('Choose the full-tunnel identity first.')), 'warning');
			if (newMode == 'split' && !split)
				return ui.addNotification(null, E('p', {}, _('Choose the split-tunnel identity first.')), 'warning');

			ui.showModal(_('Applying'), [ E('p', { 'class': 'spinning' },
				_('Switching to %s: restarting ziti-edge-tunnel and reloading the firewall...').format(newMode.toUpperCase())) ]);

			return callSet(newMode, full, split).then(function (res) {
				ui.hideModal();
				if (res && res.error)
					return ui.addNotification(null, E('p', {}, _('Failed: ') + (res.error.message || 'unknown')), 'danger');
				ui.addNotification(null, E('p', {}, _('Switched to %s. Reloading...').format(newMode.toUpperCase())), 'info');
				window.setTimeout(function () { location.reload(); }, 3000);
			}).catch(function (e) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, _('Error: ') + e.message), 'danger');
			});
		}

		function modeBtn(m, label) {
			var on = (mode == m);
			return E('button', {
				'class': 'btn cbi-button ' + (on ? 'cbi-button-positive' : 'cbi-button-action'),
				'style': 'min-width:9em;margin-right:.5em',
				'disabled': (!haveIds || on) ? 'disabled' : null,
				'click': ui.createHandlerFn(this, function () { return apply(m); })
			}, label);
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('OpenZiti Tunnel Mode'),
				E('small', { 'style': 'margin-left:.75em;color:#999;font-weight:normal' }, UI_BUILD) ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Route all client traffic home (full) or only chosen services (split). '),
				E('a', { 'href': DOC_URL, 'target': '_blank', 'rel': 'noreferrer' }, _('Documentation')),
				'.'
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('p', { 'style': 'font-size:1.1em' }, [
					_('Current mode: '),
					E('strong', { 'style': 'color:' + (mode == 'full' ? '#c44' : '#5aa726') }, mode.toUpperCase())
				]),
				E('p', {}, [ _('Loaded identity right now: '),
					E('strong', {}, activeNames.length ? activeNames.join(', ') : _('none')) ]),
				E('div', {}, [ modeBtn('full', _('Full tunnel')), modeBtn('split', _('Split tunnel')) ]),
				E('p', { 'class': 'cbi-section-descr' },
					_('The highlighted button is the active mode. Switching restarts ziti-edge-tunnel and reloads the firewall -- a brief blip for connected clients. Full removes direct LAN->WAN (fail-closed).'))
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Identities')),
				haveIds ? null : E('div', { 'class': 'alert-message warning' },
					_('No identities enrolled. Enroll one on the Identities page first.')),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Full-tunnel identity')),
					E('div', { 'class': 'cbi-value-field' }, [ fullSel ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Split-tunnel identity')),
					E('div', { 'class': 'cbi-value-field' }, [ splitSel ])
				])
			])
		]);
	}
});
