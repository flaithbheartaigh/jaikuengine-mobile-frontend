#!/usr/bin/perl -w

use strict;
use lib $ENV{PERL_CORE} ? '../lib/Module/Build/t/lib' : 't/lib';
use MBTest tests => 2;

use Cwd ();
my $cwd = Cwd::cwd;
my $tmp = File::Spec->catdir( $cwd, 't', '_tmp' );

use DistGen;
my $dist = DistGen->new( dir => $tmp );
$dist->regen;

#########################

use Module::Build;

my @mod = split( /::/, $dist->name );
my $file = File::Spec->catfile( $dist->dirname, 'lib', @mod ) . '.pm';
is( Module::Build->version_from_file( $file ), '0.01', 'version_from_file' );

ok( Module::Build->compare_versions( '1.01_01', '>', '1.01' ), 'compare: 1.0_01 > 1.0' );


# cleanup
$dist->remove;

use File::Path;
rmtree( $tmp );
