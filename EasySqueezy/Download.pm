package Plugins::EasySqueezy::Download;

# Copyright (C) 2026 Eradj Tursun-Zade (irage) <irage@irage.org>
# SPDX-License-Identifier: GPL-2.0-only
# This program is free software; you can redistribute it and/or modify it under the terms of
# the GNU General Public License version 2 (see LICENSE).

# A song file converted with the rules Lyrion uses for one player (plugin item 7):
#   /easysqueezy/song/<track id>.mp3?player=<mac>&bitrate=<kbps>
# Lyrion's own download (/music/<id>/download.mp3) only knows the general rules ("* *"). C-3PO
# and SqueezeDSP replace those with rules for single players, so on such servers that download
# is refused (HTTP 400), and the app can't fetch a broken next song again early. This looks the
# rule up in the player's order (this phone, any player with its id, its model, everyone), as
# the settings page does, and streams it the way Lyrion's download does. Lyrion checks the
# server password before calling it. HEAD answers without converting anything.

use strict;

use AnyEvent::Handle;
use File::Basename qw(basename);
use FileHandle;
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant APP_MODEL => 'easysqueezy';
# Output formats offered (what the app asks for when it fetches a song again).
use constant FORMATS => qw(mp3);

my $log = logger('plugin.easysqueezy');
my $CRLF = "\015\012";

sub init {
	Slim::Web::Pages->addRawFunction(qr{^/?easysqueezy/song/}, \&handler);
}

sub handler {
	my ($httpClient, $response) = @_;
	my $request = $response->request;
	my $uri     = $request->uri;
	my $path    = $uri->path;
	my %q       = $uri->query_form;
	my $isHead  = $request->method eq 'HEAD';

	my ($id, $out) = $path =~ m{easysqueezy/song/(\d+)\.(\w+)$};
	my $mac = lc($q{player} || '');
	my $bitrate = ($q{bitrate} || '') =~ /^(\d+)$/ ? $1 : 0;

	return _refuse($httpClient, $response, 400, 'expected /easysqueezy/song/<id>.mp3?player=<mac>')
		unless $id && $out && grep({ $_ eq $out } FORMATS) && $mac =~ /^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$/;

	my $track = Slim::Schema->find('Track', $id);
	return _refuse($httpClient, $response, 404, "no song file with id $id")
		unless blessed($track) && Slim::Music::Info::isSong($track) && Slim::Music::Info::isFile($track->url);

	my ($transcoder, $error) = _transcoder($track, $mac, $out, $bitrate);
	return _refuse($httpClient, $response, 400, $error) unless $transcoder;

	my $client  = Slim::Player::Client::getClient($mac);
	my $quality = $client ? preferences('server')->client($client)->get('lameQuality') : undef;
	$quality = 9 unless defined $quality && $quality =~ /^\d$/;

	my $command = Slim::Player::TranscodingHelper::tokenizeConvertCommand2($transcoder, $track->path, $track->url, 1, $quality);
	return _refuse($httpClient, $response, 400, "no command line for $transcoder->{profile}") unless $command;
	# A rule that reads the song from its input (I) gets the file piped in.
	if ($transcoder->{streamMode} eq 'I') {
		(my $file = $track->path) =~ s/([\$\"\`\\])/\\$1/g;
		$command = qq{cat "$file" | $command};
	}

	main::INFOLOG && $log->is_info && $log->info(sprintf('EasySqueezy: %s for %s (%s), rule %s%s',
		$isHead ? 'checked a download' : 'download', $mac, $track->url, $transcoder->{profile}, $isHead ? '' : ": $command"));

	_stream($httpClient, $response, $command, $isHead, $out, $track);
	return;
}

# The rule for this player and its transcoder (as getConvertCommand2 builds it), or (undef, why).
sub _transcoder {
	my ($track, $mac, $out, $bitrate) = @_;
	my $in = $track->content_type;
	return (undef, "the song is already $out: use Lyrion's own download") if $in eq $out;

	Plugins::EasySqueezy::Plugin::_rules();
	my $rule = Plugins::EasySqueezy::Plugin::_pickRule($in, $mac, $bitrate ? 1 : 0, $out, 1);
	if ($rule->{none}) {
		my @why = map { "$_->{profile} " . ($_->{state} eq 'NOBIN' ? 'needs ' . join(', ', @{ $_->{missing} || [] }) : 'is switched off') } @{ $rule->{skipped} || [] };
		return (undef, "no rule converts $in to $out for this player" . (@why ? ' (' . join('; ', @why) . ')' : ''));
	}

	my $profile = $rule->{profile};
	my $caps = $Slim::Player::TranscodingHelper::capabilities{$profile} || {};
	my $command = Slim::Player::TranscodingHelper::checkBin($profile);
	return (undef, "$profile: a program it needs is missing") unless $command;

	my $client = Slim::Player::Client::getClient($mac);
	return ({
		command          => $command,
		profile          => $profile,
		usedCapabilities => [($bitrate && $caps->{B}) ? 'B' : ()],
		streamMode       => $caps->{F} ? 'F' : 'I',
		streamformat     => $out,
		rateLimit        => $bitrate || 320,
		samplerateLimit  => 44100,
		clientid         => $mac,
		groupid          => 0,
		name             => $client ? $client->name : 'undefined',
		player           => APP_MODEL,
		channels         => $track->channels() || 2,
		sampleSize       => $track->samplesize || 16,
		sampleRate       => $track->samplerate || 44100,
		outputChannels   => 2,
		extensions       => $caps->{E},
	});
}

sub _refuse {
	my ($httpClient, $response, $code, $why) = @_;
	$log->warn("EasySqueezy: download refused ($code): $why");
	$response->code($code);
	$response->headers->remove_content_headers;
	# The reason, for the app's diagnostics log.
	$response->header('X-EasySqueezy-Error' => $why);
	Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \'', 1, 0);
	return;
}

# As Lyrion's downloadMusicFile: the converter's output to the client, chunked for HTTP/1.1.
sub _stream {
	my ($httpClient, $response, $command, $isHead, $out, $track) = @_;

	my ($in, $handle);
	my $done = 0;
	if (!$isHead) {
		$in = FileHandle->new("$command |");
		if (!$in) {
			_refuse($httpClient, $response, 500, "the converter didn't start: $!");
			return;
		}
		Slim::Utils::Network::blocking($in, 0);
	}

	$response->code(200);
	$response->content_type($Slim::Music::Info::types{$out});
	$response->header('Accept-Ranges' => 'none');
	(my $name = basename($track->path)) =~ s/\.[^.]+$/.$out/;
	$response->header('Content-Disposition' => sprintf('attachment; filename="%s"', $name));
	my $is11 = $response->request->protocol eq 'HTTP/1.1';
	$response->header('Transfer-Encoding' => 'chunked') if $is11;

	my $headers = Slim::Web::HTTP::_stringifyHeaders($response) . $CRLF;

	my $writer; $writer = sub {
		if ($headers) {
			syswrite $httpClient, $headers;
			undef $headers;
			$done = 1 if $isHead;
		}
		if ($done) {
			$handle && $handle->destroy;
			$in && $in->close;
			Slim::Web::HTTP::closeHTTPSocket($httpClient) if $httpClient->opened();
			undef $writer;
			return;
		}
		my $len = sysread $in, my $buf, 32 * 1024;
		if (!defined $len) {
			my $w; $w = AnyEvent->io(fh => $in, poll => 'r', cb => sub { undef $w; $in && $writer && $writer->() });
		}
		elsif ($len == 0) {
			$done = 1;
			if ($is11) { $handle->push_write('0' . $CRLF . $CRLF) } else { $writer->() }
		}
		else {
			$handle->push_write($is11 ? sprintf('%X', length $buf) . $CRLF . $buf . $CRLF : $buf);
		}
	};

	$handle = AnyEvent::Handle->new(
		fh         => $httpClient,
		linger     => 0,
		timeout    => 300,
		on_timeout => sub { $done = 1; $writer && $writer->() },
		on_error   => sub { $done = 1; $writer && $writer->() },
	);
	$handle->on_drain($writer);
}

1;
