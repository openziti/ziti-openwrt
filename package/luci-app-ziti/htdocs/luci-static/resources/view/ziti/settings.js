// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require form';
'require uci';

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

		o = s.option(form.Flag, 'enabled', _('Enabled'),
			_('Run ziti-edge-tunnel at boot.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'log_level', _('Log level'));
		o.value('ERROR',   'ERROR');
		o.value('WARN',    'WARN');
		o.value('INFO',    'INFO');
		o.value('DEBUG',   'DEBUG');
		o.value('VERBOSE', 'VERBOSE');
		o.value('TRACE',   'TRACE');
		o.default = 'INFO';

		return m.render();
	}
});
