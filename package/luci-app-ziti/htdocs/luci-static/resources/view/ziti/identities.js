// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require ui';
'require uci';
'require dom';

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
		return uci.load('ziti');
	},

	doEnroll: function (name, jwt) {
		// Caller validates inputs; this is defense-in-depth.
		if (!name || !jwt) return Promise.resolve();
		ui.showModal(_('Enrolling...'), [
			E('p', { 'class': 'spinning' }, _('Contacting controller and writing identity.'))
		]);
		// IMPORTANT: rpcd backend wipes the JWT staging file after use; the
		// browser-side variable holding `jwt` goes out of scope after this
		// promise resolves. We never persist the JWT in localStorage / UCI.
		return callEnroll(name, jwt).then(function (res) {
			ui.hideModal();
			if (res && res.error) {
				ui.addNotification(null,
					E('p', _('Enrollment failed: %s').format(res.error.message || res.error.code)),
					'danger');
				return;
			}
			ui.addNotification(null,
				E('p', _('Identity %q enrolled at %s').format(name, (res && res.file) || '')),
				'info');
			window.setTimeout(function () { location.reload(); }, 750);
		}).catch(function (e) {
			ui.hideModal();
			ui.addNotification(null,
				E('p', _('Enrollment failed: %s').format(e.message || e)), 'danger');
		});
	},

	doRemove: function (name) {
		if (!confirm(_('Delete identity %q? This is irreversible.').format(name)))
			return;
		return callRemove(name).then(function () {
			location.reload();
		}).catch(function (e) {
			ui.addNotification(null, E('p', _('Remove failed: %s').format(e.message || e)), 'danger');
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

	render: function () {
		var self = this;
		var sections = uci.sections('ziti', 'identity');

		var rows = [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Name')),
				E('th', { 'class': 'th' }, _('File')),
				E('th', { 'class': 'th' }, _('Enabled')),
				E('th', { 'class': 'th' }, _('Action'))
			])
		];

		if (!sections.length) {
			rows.push(E('tr', { 'class': 'tr placeholder' }, [
				E('td', { 'class': 'td', 'colspan': 4 }, _('No identities configured.'))
			]));
		} else {
			sections.forEach(function (s) {
				rows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, s.name || ''),
					E('td', { 'class': 'td' }, s.file || ''),
					E('td', { 'class': 'td' }, (s.enabled === '0') ? _('no') : _('yes')),
					E('td', { 'class': 'td' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-remove',
							'click': ui.createHandlerFn(self, 'doRemove', s.name)
						}, _('Remove'))
					])
				]));
			});
		}

		// Enrollment form. JWT is provided either by file upload or paste; in
		// either case it lives only in the browser DOM until the rpcd call
		// completes, then the form is reset.
		var nameInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'placeholder': _('e.g. home-router'),
			'pattern': '[A-Za-z0-9_-]+'
		});
		var jwtArea = E('textarea', {
			'class': 'cbi-input-textarea',
			'rows': 6,
			'style': 'width:100%;font-family:monospace;',
			'placeholder': _('Paste JWT contents here, or use the file picker below.')
		});
		var fileInput = E('input', { 'type': 'file', 'accept': '.jwt,.txt,application/jwt,text/plain' });
		fileInput.addEventListener('change', function (ev) {
			var f = ev.target.files && ev.target.files[0];
			if (!f) return;
			self.readFileAsText(f).then(function (txt) {
				jwtArea.value = txt.trim();
			});
		});

		var submitBtn = E('button', {
			'class': 'btn cbi-button cbi-button-positive',
			'click': ui.createHandlerFn(self, function () {
				var name = (nameInput.value || '').trim();
				var jwt  = (jwtArea.value  || '').trim();
				if (!name || !/^[A-Za-z0-9_-]+$/.test(name)) {
					ui.addNotification(null, E('p',
						_('Identity name is required (letters, digits, _ or - only).')), 'warning');
					return Promise.resolve();
				}
				if (!jwt) {
					ui.addNotification(null, E('p',
						_('JWT contents are required.')), 'warning');
					return Promise.resolve();
				}
				return self.doEnroll(name, jwt).finally(function () {
					// Best-effort scrub of the in-DOM JWT.
					jwtArea.value = '';
					fileInput.value = '';
				});
			})
		}, _('Enroll'));

		return E([], [
			E('h2', {}, _('OpenZiti Identities')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Enrolled')),
				E('table', { 'class': 'table cbi-section-table' }, rows)
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Enroll a new identity')),
				E('p', { 'class': 'cbi-section-descr' },
					_('Provide a one-time JWT issued by your Ziti controller. The JWT is staged in a root-only directory, consumed by ziti-edge-tunnel, and then wiped. It is never written to /tmp or to UCI.')),
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
