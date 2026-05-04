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
			E('h2', {}, _('OpenZiti Status')),
			E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left', 'width': '33%' }, _('Service')),
						E('td', { 'class': 'td left' }, [ statusBadge ])
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, _('Version')),
						E('td', { 'class': 'td left' }, version || _('unknown'))
					])
				]),
				E('div', { 'style': 'margin-top:1em;' }, [
					btn(_('Start'),   'start',   'positive'),
					' ',
					btn(_('Stop'),    'stop',    'negative'),
					' ',
					btn(_('Restart'), 'restart', 'action')
				])
			]),
			E('h3', {}, _('Enrolled Identities')),
			E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table cbi-section-table' }, idRows)
			])
		]);

		return view;
	}
});
