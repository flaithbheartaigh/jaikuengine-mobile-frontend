#!/usr/bin/perl -w

use strict;
use lib $ENV{PERL_CORE} ? '../lib/Module/Build/t/lib' : 't/lib';
use MBTest tests => 32;
use Module::Build;
use Module::Build::ConfigData;

my $have_yaml = Module::Build::ConfigData->feature('YAML_support');

#########################

use Cwd ();
my $cwd = Cwd::cwd;
my $tmp = File::Spec->catdir( $cwd, 't', '_tmp' );

use DistGen;
my $dist = DistGen->new( dir => $tmp );
$dist->remove_file( 't/basic.t' );
$dist->change_file( 'Build.PL', <<'---' );
use Module::Build;

my $build = new Module::Build(
  module_name => 'Simple',
  scripts     => [ 'script' ],
  license     => 'perl',
  requires    => { 'File::Spec' => 0 },
);
$build->create_build_script;
---
$dist->add_file( 'script', <<'---' );
#!perl -w
print "Hello, World!\n";
---
$dist->add_file( 'test.pl', <<'---' );
#!/usr/bin/perl

use Test;
plan tests => 2;

ok 1;

require Module::Build;
skip $ENV{PERL_CORE} && "no blib in core",
  $INC{'Module/Build.pm'}, qr/blib/, 'Module::Build should be loaded from blib';

print "# Cwd: ", Module::Build->cwd, "\n";
print "# \@INC: (@INC)\n";
print "Done.\n";  # t/compat.t looks for this
---
$dist->add_file( 'lib/Simple/Script.PL', <<'---' );
#!perl -w

my $filename = shift;
open FH, "> $filename" or die "Can't create $filename: $!";
print FH "Contents: $filename\n";
close FH;
---
$dist->regen;

chdir( $dist->dirname ) or die "Can't chdir to '@{[$dist->dirname]}': $!";

#########################

use Module::Build;
ok(1);

SKIP: {
  skip "no blib in core", 1 if $ENV{PERL_CORE};
  like $INC{'Module/Build.pm'}, qr/\bblib\b/, "Make sure version from blib/ is loaded";
}

#########################

my $mb = Module::Build->new_from_context;
ok $mb;
is $mb->license, 'perl';

# Make sure cleanup files added before create_build_script() get respected
$mb->add_to_cleanup('before_script');

eval {$mb->create_build_script};
is $@, '';
ok -e $mb->build_script;

is $mb->dist_dir, 'Simple-0.01';

# The 'cleanup' file doesn't exist yet
ok grep {$_ eq 'before_script'} $mb->cleanup;

$mb->add_to_cleanup('save_out');

# The 'cleanup' file now exists
ok grep {$_ eq 'before_script'} $mb->cleanup;
ok grep {$_ eq 'save_out'     } $mb->cleanup;

{
  # Make sure verbose=>1 works
  my $all_ok = 1;
  my $output = eval {
    stdout_of( sub { $mb->dispatch('test', verbose => 1) } )
  };
  $all_ok &&= is($@, '');
  $all_ok &&= like($output, qr/all tests successful/i);
  
  # This is the output of lib/Simple/Script.PL
  $all_ok &&= ok(-e $mb->localize_file_path('lib/Simple/Script'));

  unless ($all_ok) {
    # We use diag() so Test::Harness doesn't get confused.
    diag("vvvvvvvvvvvvvvvvvvvvv Simple/test.pl output vvvvvvvvvvvvvvvvvvvvv");
    diag($output);
    diag("^^^^^^^^^^^^^^^^^^^^^ Simple/test.pl output ^^^^^^^^^^^^^^^^^^^^^");
  }
}

SKIP: {
  skip( 'YAML_support feature is not enabled', 7 ) unless $have_yaml;

  my $output = eval {
    stdout_of( sub { $mb->dispatch('disttest') } )
  };
  is $@, '';
  
  # After a test, the distdir should contain a blib/ directory
  ok -e File::Spec->catdir('Simple-0.01', 'blib');
  
  eval {$mb->dispatch('distdir')};
  is $@, '';
  
  # The 'distdir' should contain a lib/ directory
  ok -e File::Spec->catdir('Simple-0.01', 'lib');
  
  # The freshly run 'distdir' should never contain a blib/ directory, or
  # else it could get into the tarball
  ok ! -e File::Spec->catdir('Simple-0.01', 'blib');

  # Make sure all of the above was done by the new version of Module::Build
  my $fh = IO::File->new(File::Spec->catfile($dist->dirname, 'META.yml'));
  my $contents = do {local $/; <$fh>};
  $contents =~ /Module::Build version ([0-9_.]+)/m;
  cmp_ok $1, '==', $mb->VERSION, "Check version used to create META.yml: $1 == " . $mb->VERSION;

  SKIP: {
    skip( "not sure if we can create a tarball on this platform", 1 )
      unless $mb->check_installed_status('Archive::Tar', 0) ||
	     $mb->isa('Module::Build::Platform::Unix');

    $mb->add_to_cleanup($mb->dist_dir . ".tar.gz");
    eval {$mb->dispatch('dist')};
    is $@, '';
  }

}

{
  # Make sure the 'script' file was recognized as a script.
  my $scripts = $mb->script_files;
  ok $scripts->{script};
  
  # Check that a shebang line is rewritten
  my $blib_script = File::Spec->catdir( qw( blib script script ) );
  ok -e $blib_script;
  
  my $fh = IO::File->new($blib_script);
  my $first_line = <$fh>;
  isnt $first_line, "#!perl -w\n", "should rewrite the shebang line";
}

{
  # Check PPD
  $mb->dispatch('ppd', args => {codebase => '/path/to/codebase'});

  my $ppd = slurp('Simple.ppd');

  # This test is quite a hack since with XML you don't really want to
  # do a strict string comparison, but absent an XML parser it's the
  # best we can do.
  is $ppd, <<'EOF';
<SOFTPKG NAME="Simple" VERSION="0,01,0,0">
    <TITLE>Simple</TITLE>
    <ABSTRACT>Perl extension for blah blah blah</ABSTRACT>
    <AUTHOR>A. U. Thor, a.u.thor@a.galaxy.far.far.away</AUTHOR>
    <IMPLEMENTATION>
        <DEPENDENCY NAME="File-Spec" VERSION="0,0,0,0" />
        <CODEBASE HREF="/path/to/codebase" />
    </IMPLEMENTATION>
</SOFTPKG>
EOF
}


eval {$mb->dispatch('realclean')};
is $@, '';

ok ! -e $mb->build_script;
ok ! -e $mb->config_dir;
ok ! -e $mb->dist_dir;

chdir( $cwd ) or die "Can''t chdir to '$cwd': $!";
$dist->remove;

SKIP: {
  skip( 'Windows-only test', 4 ) unless $^O =~ /^MSWin/;

  my $script_data = <<'---';
@echo off
echo Hello, World!
---

  $dist = DistGen->new( dir => $tmp );
  $dist->change_file( 'Build.PL', <<'---' );
use Module::Build;
my $build = new Module::Build(
  module_name => 'Simple',
  scripts     => [ 'bin/script.bat' ],
  license     => 'perl',
);
$build->create_build_script;
---
  $dist->add_file( 'bin/script.bat', $script_data );

  $dist->regen;
  chdir( $dist->dirname ) or die "Can't chdir to '@{[$dist->dirname]}': $!";

  $mb = Module::Build->new_from_context;
  ok $mb;

  eval{ $mb->dispatch('build') };
  is $@, '';

  my $script_file = File::Spec->catfile( qw(blib script), 'script.bat' );
  ok -f $script_file, "Native batch file copied to 'scripts'";

  my $out = slurp( $script_file );
  is $out, $script_data, '  unmodified by pl2bat';

  chdir( $cwd ) or die "Can''t chdir to '$cwd': $!";
  $dist->remove;
}

# cleanup
chdir( $cwd ) or die "Can''t chdir to '$cwd': $!";
$dist->remove;

use File::Path;
rmtree( $tmp );
