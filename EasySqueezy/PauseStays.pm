package Plugins::EasySqueezy::PauseStays;

# Copyright (C) 2026 Eradj Tursun-Zade (irage) <irage@irage.org>
# SPDX-License-Identifier: GPL-2.0-only
# This program is free software; you can redistribute it and/or modify it under the terms of
# the GNU General Public License version 2 (see LICENSE).

# Pause stays paused (plugin item 9, the app's scenario 19).
#
# On every reconnect Lyrion calls resumeOnPower(), which plays the queue if the player isn't
# playing and its client pref playingAtPowerOff is set. That pref is written when the
# connection really drops (playing or not), but only cleared when that resume happens. So: a
# dead spot while playing sets it; the phone carries on playing, nothing resumes, it stays set;
# the user pauses later (Android Auto, Material Skin); the next reconnect that replaces the
# connection (a network switch, which Lyrion closes as a 'reconnect' without saving anything)
# finds it still set and presses Play. Music starts by itself, in a parked car.
#
# Fix: when an EasySqueezy phone is paused or stopped while powered on, the pref is set to 0,
# as it would be after a real disconnect in that state. A player switched off while playing
# keeps it (Lyrion sets it then on purpose, to resume when switched on), and Lyrion's own
# "resume on power on" setting is left alone.

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant APP_MODEL => 'easysqueezy';

my $log = logger('plugin.easysqueezy');
my $prefs = preferences('plugin.easysqueezy');
my $serverPrefs = preferences('server');

sub init {
	Slim::Control::Request::subscribe(\&_event, [['playlist', 'pause', 'stop']]);
}

sub _event {
	my $request = shift;
	return unless $prefs->get('pauseStays');

	my $client = $request->client or return;
	return unless $client->model eq APP_MODEL;
	# Switched off: Lyrion keeps "playing at power off" to resume when it's switched on again.
	return unless $client->power;

	# Whatever the notification (pause toggles, 'playlist pause 1', stop, end of the queue): what
	# counts is the state it left the player in.
	my $paused = $client->isPaused ? 'paused' : $client->isStopped ? 'stopped' : return;

	my $cprefs = $serverPrefs->client($client);
	return unless $cprefs->get('playingAtPowerOff');
	$cprefs->set('playingAtPowerOff', 0);
	main::INFOLOG && $log->is_info && $log->info(sprintf(
		'EasySqueezy: %s (%s) %s: cleared "playing at power off", so a reconnect doesn\'t resume it', $client->name, $client->id, $paused));
}

1;
