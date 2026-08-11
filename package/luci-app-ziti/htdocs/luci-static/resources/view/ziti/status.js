// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

var callZitiStatus = rpc.declare({
	object: 'ziti',
	method: 'status',
	expect: { }
});

var callServiceAction = rpc.declare({
	object: 'ziti',
	method: 'service_action',
	params: [ 'action' ],
	expect: { }
});

var callSetAutostart = rpc.declare({
	object: 'ziti',
	method: 'set_autostart',
	params: [ 'enabled' ],
	expect: { }
});

var UI_BUILD = 'ui 20260811-182440';

return view.extend({
	handleSaveApply: null,
	handleSave:      null,
	handleReset:     null,

	load: function () {
		return callZitiStatus();
	},

	render: function (data) {
		data = data || {};
		var running    = !!data.running;
		var version    = data.version || '';
		var identities = Array.isArray(data.identities) ? data.identities : [];
		var autostart  = !!data.autostart;
		var guardState = data.guard_state || '';
		var bootFails  = parseInt(data.boot_failures, 10) || 0;

		var statusBadge = E('span', {
			'class': running ? 'label success' : 'label warning',
			'style': 'padding:2px 8px;border-radius:3px;'
		}, running ? _('running') : _('stopped'));

		var idRows = [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Name')),
				E('th', { 'class': 'th' }, _('Controller')),
				E('th', { 'class': 'th' }, _('Status')),
				E('th', { 'class': 'th' }, _('File'))
			])
		];

		if (identities.length === 0) {
			idRows.push(E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': 4 }, _('No identities enrolled.'))
			]));
		} else {
			identities.forEach(function (id) {
				idRows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, id.name || ''),
					E('td', { 'class': 'td' }, id.controller || '-'),
					E('td', { 'class': 'td' }, id.status || '-'),
					E('td', { 'class': 'td' }, id.file || '-')
				]));
			});
		}

		var btn = function (label, action, style) {
			return E('button', {
				'class': 'btn cbi-button cbi-button-' + style,
				'click': ui.createHandlerFn(this, function () {
					return callServiceAction(action).then(function () {
						ui.addNotification(null,
							E('p', _('Service %s requested.').format(action)), 'info');
						window.setTimeout(function () { location.reload(); }, 750);
					}).catch(function (e) {
						ui.addNotification(null,
							E('p', _('Failed: %s').format(e.message || e)), 'danger');
					});
				})
			}, label);
		};

		var view = E([], [
			E('h2', {}, [ _('OpenZiti Status'),
				E('small', { 'style': 'margin-left:.75em;color:#999;font-weight:normal' }, UI_BUILD) ]),
			E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left', 'width': '33%' }, _('Service')),
						E('td', { 'class': 'td left' }, [ statusBadge ])
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, _('Version')),
						E('td', { 'class': 'td left' }, version || _('unknown'))
					]),
					guardState ? E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, _('Last boot check')),
						E('td', { 'class': 'td left' }, (function () {
							// PASS = green; anything falling open or incomplete = warning.
							var bad = /fall-open|FAIL|INCOMPLETE/.test(guardState);
							var pass = /PASS/.test(guardState);
							var color = bad ? '#c44' : (pass ? '#5aa726' : '#999');
							var txt = guardState;
							if (bootFails > 0)
								txt += _(' (%d consecutive boot failure(s))').format(bootFails);
							return E('span', { 'style': 'color:' + color }, txt);
						})())
					]) : ''
				]),
				E('div', { 'style': 'margin-top:1em;' }, [
					btn(_('Start'),   'start',   'positive'),
					' ',
					btn(_('Stop'),    'stop',    'negative'),
					' ',
					btn(_('Restart'), 'restart', 'action')
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Start at boot')),
				E('div', {}, (function () {
					var cb = E('input', { 'type': 'checkbox', 'style': 'vertical-align:middle;margin-right:.4em' });
					cb.checked = autostart;
					cb.addEventListener('change', function () {
						callSetAutostart(cb.checked).then(function (res) {
							if (res && res.error) throw new Error(res.error.message || res.error.code);
							ui.addNotification(null, E('p', {}, _('Start at boot %s.').format(cb.checked ? _('enabled') : _('disabled'))), 'info');
						}).catch(function (e) {
							cb.checked = !cb.checked;
							ui.addNotification(null, E('p', {}, _('Failed to change autostart: %s').format(e.message || e)), 'danger');
						});
					});
					return E('label', {}, [ cb, _('Start ziti-edge-tunnel automatically on boot') ]);
				})())
			]),
			E('h3', {}, _('Enrolled Identities')),
			E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table cbi-section-table' }, idRows)
			])
		]);

		return view;
	}
});
