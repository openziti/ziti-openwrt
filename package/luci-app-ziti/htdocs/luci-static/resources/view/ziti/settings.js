// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require dom';

var UI_BUILD = 'ui 20260811-182440';

var callCheck = rpc.declare({
	object: 'ziti', method: 'check_update', expect: { }
});
var callUpgrade = rpc.declare({
	object: 'ziti', method: 'upgrade_zet', expect: { }
});

return view.extend({
	load: function () {
		return uci.load('ziti');
	},

	render: function () {
		var m, s, o;

		m = new form.Map('ziti', _('OpenZiti Settings'),
			_('Configure the ziti-edge-tunnel service. Identities are managed on the Identities page.'));

		s = m.section(form.NamedSection, 'main', 'ziti', _('Main'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enabled'), _('Run ziti-edge-tunnel at boot.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'log_level', _('Log level'));
		o.value('ERROR', 'ERROR'); o.value('WARN', 'WARN'); o.value('INFO', 'INFO');
		o.value('DEBUG', 'DEBUG'); o.value('VERBOSE', 'VERBOSE'); o.value('TRACE', 'TRACE');
		o.default = 'INFO';

		var results = E('div', { 'style': 'margin:.5em 0' },
			[ E('em', {}, _('Click "Check for updates" to query the signed feed.')) ]);

		function doUpgrade(candidate) {
			if (!confirm(_('Upgrade ziti-edge-tunnel to %s and restart it? Connected clients will blip briefly.').format(candidate)))
				return;
			ui.showModal(_('Upgrading'), [ E('p', { 'class': 'spinning' },
				_('Verifying the feed signature, installing, and restarting ziti-edge-tunnel...')) ]);
			return callUpgrade().then(function (res) {
				ui.hideModal();
				if (res && res.error)
					return ui.addNotification(null, E('p', {}, _('Upgrade failed: ') + (res.error.message || res.error.code)), 'danger');
				ui.addNotification(null, E('p', {}, _('Upgraded to %s. Reloading...').format((res && res.version) || '')), 'info');
				window.setTimeout(function () { location.reload(); }, 3000);
			}).catch(function (e) {
				ui.hideModal();
				ui.addNotification(null, E('p', {}, _('Upgrade error: ') + e.message), 'danger');
			});
		}

		function doCheck() {
			ui.showModal(_('Checking'), [ E('p', { 'class': 'spinning' },
				_('Refreshing the feed and verifying its signature...')) ]);
			return callCheck().then(function (r) {
				ui.hideModal();
				r = r || {};
				var upgradable = !!r.upgradable;
				var kids = [
					E('div', {}, [ _('Source feed: '), E('code', {}, r.feed || _('(none configured)')) ]),
					E('div', {}, [ _('Signature: '), r.verified
						? E('span', { 'style': 'color:#5aa726;font-weight:bold' }, _('verified (signed by the project)'))
						: E('span', { 'style': 'color:#c44;font-weight:bold' }, _('NOT verified')) ]),
					E('div', {}, [ _('Installed: '), E('strong', {}, r.installed || _('?')),
						_('  Newest in feed: '), E('strong', {}, r.candidate || _('?')) ])
				];
				if (upgradable && r.verified)
					kids.push(E('div', { 'style': 'margin-top:.5em' }, [
						E('button', { 'class': 'btn cbi-button cbi-button-positive',
							'click': ui.createHandlerFn(this, function () { return doUpgrade(r.candidate); }) },
							_('Upgrade to %s').format(r.candidate)) ]));
				else if (upgradable && !r.verified)
					kids.push(E('div', { 'class': 'alert-message warning' },
						_('An update is available but the feed signature did not verify -- not offering the upgrade.')));
				else
					kids.push(E('div', {}, E('em', {}, _('Up to date.'))));
				dom.content(results, kids);
			}).catch(function (e) {
				ui.hideModal();
				dom.content(results, E('div', { 'class': 'alert-message warning' }, _('Check failed: ') + e.message));
			});
		}

		return m.render().then(function (mapEl) {
			return E([], [
				E('div', { 'style': 'float:right;color:#999' }, UI_BUILD),
				mapEl,
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Updates')),
					E('p', { 'class': 'cbi-section-descr' },
						_('Upgrades come only from the project feed on GitHub and are refused unless its signature verifies against the imported key.')),
					E('button', { 'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, doCheck) }, _('Check for updates')),
					results
				])
			]);
		});
	}
});
