#!/usr/bin/env perl

# freshrpm -- a tool to build RPM packages off GIT snapshots,
# reusing the release SPEC files

# Copyright (C) 2016 Lubomir Rintel
# You can use and distribute this script under the terms of GNU General Public License, any version

use strict;
use warnings;

package Package;

use YAML;
use LWP::Simple;

sub merged
{
	my $model = shift;
	my $entry = shift;

	my $merges = delete $model->{$entry}{merge};
	foreach my $m (@$merges) {
		my $mergee = merged ($model, $m);
		%{$model->{$entry}} = (%$mergee, %{$model->{$entry}});
	}
	return $model->{$entry};
}

sub new
{
	my $class = shift;
	my $s = pop;

	die "No package name" unless $s->{name};
	my $y = { map { %{YAML::LoadFile ($_)} } @_ };
	$y->{$s->{name}} = {%{$y->{$s->{name}}}, %$s};
	$y->{$s->{name}}{merge} ||= [];
	push @{$y->{$s->{name}}{merge}}, 'default';

	return bless merged ($y, $s->{name}), $class;
}

my $lib = {
	fedora_spec => sub {
		my $name = shift->{name};
		return "http://pkgs.fedoraproject.org/cgit/rpms/$name.git/plain/$name.spec";
	},
	gnome_cgit => sub {
		my $upstream = shift->upstream;
		return "https://git.gnome.org/browse/$upstream";
	},
	freedesktop_cgit => sub {
		my $self = shift;
		my $upstream = $self->upstream;
		my $owner = $self->owner;

		$owner .= '/' if $owner;
		return "https://cgit.freedesktop.org/$owner$upstream";
	},
	cgit_tarball => sub {
		my $self = shift;
		my $upstream = $self->upstream;
		my ($commit) = $self->commit;
		return $self->cgit_base."/snapshot/$upstream-$commit.tar.xz";
	},
	cgit_web => sub {
		my $self = shift;
		return $self->cgit_base."/commit/?id=$self->{branch}";
	},
	cgit_commit => sub {
		 qr{<tr><th>commit</th><td colspan='2' class='sha1'><a href='[^']*id=(([^']{7})[^']*)'>};
	},
	github_web => sub {
		my $self = shift;
		my $upstream = $self->upstream;
		my $owner = $self->owner;

		$owner .= '/' if $owner;
		return "https://github.com/$owner$upstream/commits/$self->{branch}";
	},
	github_commit => sub {
		qr{<a href="https://github.com/[^/"]*/[^/"]*/commits/(([^"]{7})[^"]*)"[^>]*>Permalink</a>};
	},
	github_tarball => sub {
		my $self = shift;
		my $upstream = $self->upstream;
		my $owner = $self->owner;
		my ($commit) = $self->commit;
		return "https://github.com/$owner/$upstream/archive/$commit/$upstream-$commit.tar.gz";
	},

};

sub AUTOLOAD
{
	my $entry = shift;
	my $key =  $Package::AUTOLOAD =~ s/.*:://r;

	die "$key not defined" unless $entry->{$key};
	die "$entry->{$key} not allowed" unless $lib->{$entry->{$key}};
	$lib->{$entry->{$key}}->($entry)
}

sub owner
{
	my $self = shift;
	$self->{owner} // $self->{name};
}

sub upstream
{
	my $self = shift;
	$self->{upstream} // $self->{name};
}

sub spec
{
	my $self = shift;
	get $self->spec_url or die "Can't get spec file";
}

sub commit
{
	my $self = shift;
	my $web = get ($self->git_web) or die "Can't fetch git web: ".$self->git_web;
	$self->{commit} //= [$web =~ $self->git_commit];
	return @{$self->{commit}};
}

sub write_spec
{
	my $self = shift;
	my $spec = shift;

	my $name = $self->{name}.'.spec';
	open (my $file, '>:utf8', $name) or die "$name: $!";
	print $file $spec;

	return $name;
}

package main;

my $rpmargs = "-bs";
my $s = {};
while ($_ = shift @ARGV) {
	if (/^--([^=]*)(=(.*))?/) {
		$s->{$1} = $3 // shift @ARGV;
		die "$1 needs a value" unless defined $s->{$1};
	} elsif (/^(-b.*)/) {
		$rpmargs = $_;
	} else {
		die "Package already set: $s->{name}" if $s->{name};
		$s->{name} = $_;
	}

}

my $p = new Package ('macros.yaml', 'packages.yaml', $s);

my $spec = $p->spec;
my $upstream = $p->upstream;
my ($commit, $short) = $p->commit;
my $source0 = $p->tarball or die "No source";

$spec =~ s/^(Source0*:\s+).*/$1$source0/mi
	or die 'Could not patch in the source file';
$spec =~ s/^(Patch.*|%patch.*)/#$1/gm
	if $p->{keeppatches} // 1;
$spec =~ s/^(%setup.*\S)\s+-n.*/$1/m;
$spec =~ s/^(%setup.*)/$1 -n $upstream-$commit$p->{path}/m
	or die 'Could not patch %setup arguments';
$spec =~ s/^(%build)/$1\nintltoolize --force/m
	if $p->{intltoolize} // ($spec =~ /intltool/ and not $spec =~ /^(intltoolize|autogen)/);
$spec =~ s/^(%build)/$1\nautoreconf -i -f/m
	if $p->{autoreconf} // ($spec =~ /%configure/ and not $spec =~ /^auto(gen|(re)?conf)/);
$spec =~ s/^(%build)/$1\ngtkdocize/m
	if $p->{gtkdocize} // ($spec =~ /gtk-doc/ and not $spec =~ /^(gtkdocize|autogen)/);
$spec =~ s/^(%build)/$1\ntouch ChangeLog/m
	if $p->{ac_missing};
$spec =~ s/^(%description)/BuildRequires: automake autoconf intltool libtool\n\n$1/m;

my $name = $p->write_spec ($spec);
my (undef, undef, undef, $mday, $mon, $year) = gmtime (time);
my $release = [split /\s+/, `rpm --define 'dist %{nil}' --qf '%{release}\n' -q --specfile $name`]->[0];
$release =~ s/([\d\.]*\d).*/$1/;
$release =~ s/(\d+)$/$1 + 1/e;
$release .= sprintf ".%04d%02d%02dgit$short%%{?dist}", $year + 1900, $mon + 1, $mday;
$spec =~ s/^(Release:\s*).*/$1$release/mi
	or die 'Could not patch in the release number';

die unless $name eq $p->write_spec ($spec);
exec 'rpmbuild', '--define', '_disable_source_fetch 0', $rpmargs, $name;
