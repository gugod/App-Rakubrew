package App::Rakudobrew::Download;
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw();

use strict;
use warnings;
use 5.010;
use Furl;
use JSON;
use Config;
use IO::Uncompress::Unzip qw( $UnzipError );
use File::Path qw( make_path );
use File::Spec::Functions qw( updir splitpath catfile catdir );
use App::Rakudobrew::Variables;
use App::Rakudobrew::Tools;
use App::Rakudobrew::VersionHandling;

use Data::Printer;

my $release_index_url   = 'https://rakudo.org/dl/rakudo';
my $download_url_prefix = 'https://rakudo.org/dl/rakudo/';

sub download_precomp_archive {
    my ($impl, $ver) = @_;

    my $name = "$impl-$ver";

    chdir $versions_dir;
    if (-d $name) {
        say STDERR "$name is already installed.";
        exit 1;
    }

    my $furl = Furl->new();
    my $release_index = _download_release_index($furl);
    my @matching_releases =
        sort { $b->{build_rev} cmp $a->{build_rev} }
        grep {
               $_->{name}     eq 'rakudo'
            && $_->{type}     eq 'archive'
            && $_->{platform} eq _my_platform()
            && $_->{arch}     eq _my_arch()
            && $_->{format}   eq (_my_platform() eq 'win' ? 'zip' : 'tar.gz')
            && ($ver ? $_->{ver} eq $ver : $_->{latest})
        } @$release_index;
    @matching_releases = grep { $_->{build_rev} eq $matching_releases[0]->{build_rev} } @matching_releases;

    if (!@matching_releases) {
        say STDERR 'Couldn\'t find a precomp release for OS: "' . _my_platform() . '", architecture: "' . _my_arch() . '"';
        exit 1;
    }
    if (@matching_releases > 1) {
        say STDERR 'Multiple releases found for your architecture. Don\'t know what to install. This shouldn\'t happen.';
        exit 1;
    }

    say 'Downloading ' . $matching_releases[0]->{url};
    my $res = $furl->get($matching_releases[0]->{url});

    say 'Extracting';
    if (_my_platform() eq 'win') {
        _unzip(\($res->body), $name);
    }
    else {
        _untar($res->body, $name);
    }
}

sub _my_platform {
	my %oses = (
		MSWin32 => 'win',
		dawin   => 'macos',
		linux   => 'linux',
		openbsd => 'openbsd',
	);
    return $oses{$^O} // $^O;
}

sub _my_arch {
    my $arch =
        $Config{archname} =~ /x86_64/i ? 'x86_64' :
        $Config{archname} =~ /amd64/i  ? 'x86_64' :
        $Config{archname} =~ /x86/i    ? 'x86'    :
        '';
    unless ($arch) {
        say STDERR 'Couldn\'t detect system architecture.';
        exit 1;
    }
    return $arch;
}

sub _download_release_index {
    my $furl = shift;
    my $res = $furl->get($release_index_url);
    unless ($res->is_success) {
        say STDERR "Couldn\'t fetch release index at $release_index_url. Error: $res->status_line";
        exit 1;
    }
    return decode_json($res->content);
}

sub _untar {
    my ($data, $target) = @_;
    mkdir $target if !-d $target;
    chdir $target;
    open (TAR, '| tar -xz --strip-components=1');
    print TAR $data;
    close TAR;
}

sub _unzip {
    my ($data_ref, $target) = @_;

    my $zip = IO::Uncompress::Unzip->new($data_ref);
    unless ($zip) {
        say STDERR "Unzipping failed. Error: $UnzipError";
        exit 1;
	}

    my $status;
    for ($status = 1; $status > 0; $status = $zip->nextStream()) {
        my $header = $zip->getHeaderInfo();

        my ($vol, $path, $file) = splitpath($header->{Name});

        if (index($path, updir()) != -1) {
            say STDERR 'Found updirs in zip file, this is bad. Aborting.';
            exit 1;
        }

        my $target_dir  = catdir($target, $path);

        unless (-d $target_dir) {
            unless (make_path($target_dir)) {
                say STDERR "Failed to create directory $target_dir. Error: $!";
                exit 1;
            }
        }

        next unless $file;

        my $target_file = catfile($target, $path, $file);

        unless (open(FH, '>', $target_file)) {
            say STDERR "Failed to write $target_file. Error: $!";
            exit 1;
        }

        my $buf;
        while (($status = $zip->read($buf)) > 0) {
            print FH $buf;
        }
        close FH;
    }

    if ($status < 0) {
        say STDERR "Failed to extract archive.";
        exit 1;
    }
}

