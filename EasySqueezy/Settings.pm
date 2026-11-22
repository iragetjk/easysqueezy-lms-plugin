package Plugins::EasySqueezy::Settings;

# Copyright (C) 2026 Eradj Tursun-Zade (irage) <irage@irage.org>
# SPDX-License-Identifier: GPL-2.0-only
# This program is free software; you can redistribute it and/or modify it under the terms of
# the GNU General Public License version 2 (see LICENSE).

# The plugin's page in Lyrion's settings (Settings > Advanced, or Manage Plugins > Settings).
# Shows the version and the conversion rules EasySqueezy phones get; the server admin decides whether the app may include server log lines
# in a shared diagnostics log.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.easysqueezy');

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_EASYSQUEEZY') }

sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/EasySqueezy/settings/basic.html') }

sub prefs { ($prefs, 'shareLog', 'ownRules', 'pauseStays') }

sub handler {
	my ($class, $client, $params) = @_;
	$params->{easysqueezy_version} = Plugins::EasySqueezy::Plugin->version;
	$params->{easysqueezy_rules} = Plugins::EasySqueezy::Plugin::ruleReport();

	# Remote access (Tailscale): buttons on the page.
	my $ts = 'Plugins::EasySqueezy::Tailscale';
	my $error = '';
	if    ($params->{ts_install}) { $error = $ts->can('install')->('install') }
	elsif ($params->{ts_update})  { $error = $ts->can('install')->('update') }
	elsif ($params->{ts_login})   { $error = $ts->can('login')->($params->{ts_authkey}) }
	elsif ($params->{ts_logout})  { $error = $ts->can('logout')->() }
	elsif ($params->{ts_remove})  { $error = $ts->can('remove')->() }
	elsif ($params->{ts_start})   { $ts->can('setEnabled')->(1) }
	elsif ($params->{ts_stop})    { $ts->can('setEnabled')->(0) }
	# The auth key is used once and never kept or shown again.
	delete $params->{ts_authkey};
	$params->{easysqueezy_ts} = $ts->can('status')->();
	$params->{easysqueezy_zt} = eval { Plugins::EasySqueezy::ZeroTier::status() } || {};
	$params->{easysqueezy_ts}->{action_error} = $error if $error;
	return $class->SUPER::handler($client, $params);
}

1;
