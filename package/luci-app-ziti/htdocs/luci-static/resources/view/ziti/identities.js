// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';

var UI_BUILD = 'ui 20260812-175409';

var callList = rpc.declare({
	object: 'ziti',
	method: 'list_identities',
	expect: { }
});

var callEnroll = rpc.declare({
	object: 'ziti',
	method: 'enroll',
	params: [ 'name', 'jwt' ],
	expect: { }
});

var callRemove = rpc.declare({
	object: 'ziti',
	method: 'remove_identity',
	params: [ 'name' ],
	expect: { }
});

return view.extend({
	handleSaveApply: null,
	handleSave:      null,
	handleReset:     null,

	load: function () {
		return callList().catch(function () { return { identities: [] }; });
	},

	doEnroll: function (name, jwt) {
		if (!name || !jwt) return Promise.resolve();
		ui.showModal(_('Enrolling...'), [
			E('p', { 'class': 'spinning' }, _('Contacting controller and writing identity.'))
		]);
		return callEnroll(name, jwt).then(function (res) {
			ui.hideModal();
			if (res && res.error) {
				ui.addNotification(null,
					E('p', {}, _('Enrollment failed: %s').format(res.error.message || res.error.code)), 'danger');
				return;
			}
			ui.addNotification(null,
				E('p', {}, _('Identity %q enrolled at %s').format(name, (res && res.file) || '')), 'info');
			window.setTimeout(function () { location.reload(); }, 750);
		}).catch(function (e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Enrollment failed: %s').format(e.message || e)), 'danger');
		});
	},

	doRemove: function (name) {
		if (!confirm(_('Delete identity %q? This is irreversible.').format(name)))
			return;
		return callRemove(name).then(function () {
			location.reload();
		}).catch(function (e) {
			ui.addNotification(null, E('p', {}, _('Remove failed: %s').format(e.message || e)), 'danger');
		});
	},

	readFileAsText: function (file) {
		return new Promise(function (resolve, reject) {
			var fr = new FileReader();
			fr.onload  = function () { resolve(String(fr.result || '')); };
			fr.onerror = function () { reject(new Error('read failed')); };
			fr.readAsText(file);
		});
	},

	render: function (data) {
		var self = this;
		var ids = (data && data.identities) || [];

		var rows = [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Name')),
				E('th', { 'class': 'th' }, _('File')),
				E('th', { 'class': 'th' }, _('Enabled')),
				E('th', { 'class': 'th' }, _('Action'))
			])
		];

		if (!ids.length) {
			rows.push(E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': 4 }, _('No identities enrolled.'))
			]));
		} else {
			ids.forEach(function (it) {
				rows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, it.name || ''),
					E('td', { 'class': 'td' }, it.file || ''),
					E('td', { 'class': 'td' }, it.enabled ? _('yes') : _('no')),
					E('td', { 'class': 'td' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-remove',
							'click': ui.createHandlerFn(self, 'doRemove', it.name)
						}, _('Remove'))
					])
				]));
			});
		}

		var nameInput = E('input', {
			'type': 'text', 'class': 'cbi-input-text',
			'placeholder': _('e.g. home-router'), 'pattern': '[A-Za-z0-9_-]+'
		});
		var jwtArea = E('textarea', {
			'class': 'cbi-input-textarea', 'rows': 6,
			'style': 'width:100%;font-family:monospace;',
			'placeholder': _('Paste JWT contents here, or use the file picker below.')
		});
		var fileInput = E('input', { 'type': 'file', 'accept': '.jwt,.txt,application/jwt,text/plain' });
		fileInput.addEventListener('change', function (ev) {
			var f = ev.target.files && ev.target.files[0];
			if (!f) return;
			self.readFileAsText(f).then(function (txt) { jwtArea.value = txt.trim(); });
		});

		var submitBtn = E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'click': ui.createHandlerFn(self, function () {
				var name = (nameInput.value || '').trim();
				var jwt  = (jwtArea.value  || '').trim();
				if (!name || !/^[A-Za-z0-9_-]+$/.test(name)) {
					ui.addNotification(null, E('p', {}, _('Identity name is required (letters, digits, _ or - only).')), 'warning');
					return Promise.resolve();
				}
				if (!jwt) {
					ui.addNotification(null, E('p', {}, _('JWT contents are required.')), 'warning');
					return Promise.resolve();
				}
				return self.doEnroll(name, jwt).finally(function () {
					jwtArea.value = ''; fileInput.value = '';
				});
			})
		}, _('Enroll'));

		return E([], [
			E('h2', {}, [ _('OpenZiti Identities'),
				E('small', { 'style': 'margin-left:.75em;color:#999;font-weight:normal' }, UI_BUILD) ]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Enrolled')),
				E('table', { 'class': 'table cbi-section-table' }, rows)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Enroll a new identity')),
				E('p', { 'class': 'cbi-section-descr' },
					_('Provide a one-time JWT issued by your Ziti controller. The JWT is staged in a root-only directory, consumed by ziti-edge-tunnel, and then wiped -- never written to /tmp or UCI.')),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Identity name')),
					E('div', { 'class': 'cbi-value-field' }, [ nameInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('JWT file')),
					E('div', { 'class': 'cbi-value-field' }, [ fileInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('JWT contents')),
					E('div', { 'class': 'cbi-value-field' }, [ jwtArea ])
				]),
				E('div', { 'style': 'margin-top:1em;' }, [ submitBtn ])
			])
		]);
	}
});
