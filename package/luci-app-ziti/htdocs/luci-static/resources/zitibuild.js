// SPDX-License-Identifier: Apache-2.0
'use strict';
'require baseclass';

// Single source of truth for the UI build stamp shown on every ziti view. The
// dev deploy stamper rewrites the BUILD line here (one place, not per view) so a
// browser refresh visibly proves the new JS loaded.
return baseclass.extend({
	BUILD: 'ui 20260812-181450'
});
