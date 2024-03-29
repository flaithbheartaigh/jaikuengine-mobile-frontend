#testing init_and_watch

use Test::More;

use warnings;
use strict;

use Log::Log4perl;
use File::Spec;

BEGIN {
    if ($] < 5.006) {
        plan skip_all => "Only with perl >= 5.006";
    } else {
        plan tests => 29;
    }
}

my $WORK_DIR = "tmp";
if(-d "t") {
    $WORK_DIR = File::Spec->catfile(qw(t tmp));
}

unless (-e "$WORK_DIR"){
    mkdir("$WORK_DIR", 0755) || die "can't create $WORK_DIR ($!)";
}

my $testfile = File::Spec->catfile($WORK_DIR, "test17.log");

END { 
    unlink $testfile if (-e $testfile);
}

trunc($testfile);

my $testconf = File::Spec->catfile($WORK_DIR, "test17.conf");
trunc($testfile);

my $conf1 = <<EOL;
log4j.category.animal.dog   = INFO, myAppender

log4j.appender.myAppender          = Log::Log4perl::Appender::File
log4j.appender.myAppender.layout   = Log::Log4perl::Layout::SimpleLayout
log4j.appender.myAppender.filename = $testfile
log4j.appender.myAppender.mode     = append

EOL
open (CONF, ">$testconf") || die "can't open $testconf $!";
print CONF $conf1;
close CONF;

Log::Log4perl->init_and_watch($testconf, 1);

my $logger = Log::Log4perl::get_logger('animal.dog');

$logger->debug('debug message');
$logger->info('info message');

ok(! $logger->is_debug(), "is_debug - true");
ok(  $logger->is_info(),  "is_info - true");
ok(  $logger->is_warn(),  "is_warn - true");
ok(  $logger->is_error(), "is_error - true");
ok(  $logger->is_fatal(), "is_fatal - true");

# *********************************************************************
# Check if we really dont re-read the conf file if nothing has changed
# *********************************************************************

my $how_many_reads = $Log::Log4perl::Config::CONFIG_FILE_READS;
print "sleeping for 2 secs\n";
sleep 2;
$logger->is_debug();
is($how_many_reads, $Log::Log4perl::Config::CONFIG_FILE_READS,
   "no re-read until config has changed");

    # Need to sleep for at least a sec, otherwise the watcher
    # wont check
print "sleeping for 2 secs\n";
sleep 2;

# *********************************************************************
# Now, lets check what happens if the config changes
# *********************************************************************

my $conf2 = <<EOL;
log4j.category.animal.dog   = DEBUG, myAppender

log4j.appender.myAppender          = Log::Log4perl::Appender::File
log4j.appender.myAppender.layout = org.apache.log4j.PatternLayout
log4j.appender.myAppender.layout.ConversionPattern=%-5p %c - %m%n

log4j.appender.myAppender.filename = $testfile
log4j.appender.myAppender.mode     = append
EOL

open (CONF, ">$testconf") || die "can't open $testconf $!";
print CONF $conf2;
close CONF;

$logger = Log::Log4perl::get_logger('animal.dog');

$logger->debug('2nd debug message');
is($Log::Log4perl::Config::CONFIG_FILE_READS, 
   $how_many_reads + 1,
   "re-read if config has changed");

$logger->info('2nd info message');
print "sleeping for 2 secs\n";
sleep 2;
$logger->info('2nd info message again');

open (LOG, $testfile) or die "can't open $testfile $!";
my @log = <LOG>;
close LOG;
my $log = join('',@log);

is($log, "INFO - info message\nDEBUG animal.dog - 2nd debug message\nINFO  animal.dog - 2nd info message\nINFO  animal.dog - 2nd info message again\n", "1st init");
ok(  $logger->is_debug(), "is_debug - false");
ok(  $logger->is_info(),  "is_info - true");
ok(  $logger->is_warn(),  "is_warn - true");
ok(  $logger->is_error(), "is_error - true");
ok(  $logger->is_fatal(), "is_fatal - true");

# ***************************************************************
# do it 3rd time

print "sleeping for 2 secs\n";
sleep 2;

$conf2 = <<EOL;
log4j.category.animal.dog   = INFO, myAppender

log4j.appender.myAppender          = Log::Log4perl::Appender::File
log4j.appender.myAppender.layout   = Log::Log4perl::Layout::SimpleLayout
log4j.appender.myAppender.filename = $testfile
log4j.appender.myAppender.mode     = append
EOL
open (CONF, ">$testconf") || die "can't open $testconf $!";
print CONF $conf2;
close CONF;

$logger = Log::Log4perl::get_logger('animal.dog');

$logger->debug('2nd debug message');
$logger->info('3rd info message');

ok(! $logger->is_debug(), "is_debug - false");
ok(  $logger->is_info(),  "is_info - true");
ok(  $logger->is_warn(),  "is_warn - true");
ok(  $logger->is_error(), "is_error - true");
ok(  $logger->is_fatal(), "is_fatal - true");

open (LOG, $testfile) or die "can't open $testfile $!";
@log = <LOG>;
close LOG;
$log = join('',@log);

is($log, "INFO - info message\nDEBUG animal.dog - 2nd debug message\nINFO  animal.dog - 2nd info message\nINFO  animal.dog - 2nd info message again\nINFO - 3rd info message\n", "after reload");


# ***************************************************************
# Check the 'recreate' feature

trunc($testfile);
my $conf3 = <<EOL;
log4j.category.animal.dog   = INFO, myAppender

log4j.appender.myAppender          = Log::Log4perl::Appender::File
log4j.appender.myAppender.layout   = Log::Log4perl::Layout::SimpleLayout
log4j.appender.myAppender.filename = $testfile
log4j.appender.myAppender.recreate = 1
log4j.appender.myAppender.recreate_check_interval = 0
log4j.appender.myAppender.mode     = append
EOL

Log::Log4perl->init(\$conf3);

$logger = Log::Log4perl::get_logger('animal.dog');
$logger->info("test1");
open (LOG, $testfile) or die "can't open $testfile $!";
is(scalar <LOG>, "INFO - test1\n", "Before recreate");

trunc($testfile);
$logger->info("test2");
open (LOG, $testfile) or die "can't open $testfile $!";
is(scalar <LOG>, "INFO - test2\n", "After recreate");

trunc($testfile);
trunc($testconf);

sub trunc {
    open FILE, ">$_[0]" or die "Cannot open $_[0]";
    close FILE;
}

# ***************************************************************
# Check the 'recreate' feature with signal handling

SKIP: {
  skip "Signal handling not supported on Win32", 5 if $^O eq "MSWin32";

  my $conf3 = <<EOL;
    log4j.category.animal.dog   = INFO, myAppender

    log4j.appender.myAppender          = Log::Log4perl::Appender::File
    log4j.appender.myAppender.layout   = Log::Log4perl::Layout::SimpleLayout
    log4j.appender.myAppender.filename = $testfile
    log4j.appender.myAppender.recreate = 1
    log4j.appender.myAppender.recreate_check_signal = USR1
EOL

  Log::Log4perl->init(\$conf3);
  
  $logger = Log::Log4perl::get_logger('animal.dog');
  $logger->info("test1");
  ok(-f $testfile, "recreate_signal - testfile created");
  
  unlink $testfile;
  ok(!-f $testfile, "recreate_signal - testfile deleted");
  
  $logger->info("test1");
  ok(!-f $testfile, "recreate_signal - testfile still missing");
  
  ok(kill('USR1', $$), "sending signal");
  $logger->info("test1");
  ok(-f $testfile, "recreate_signal - testfile reinstated");
};

# ***************************************************************
# Check the 'recreate' feature with check_interval

trunc($testfile);
$conf3 = <<EOL;
log4j.category.animal.dog   = INFO, myAppender

log4j.appender.myAppender          = Log::Log4perl::Appender::File
log4j.appender.myAppender.layout   = Log::Log4perl::Layout::SimpleLayout
log4j.appender.myAppender.filename = $testfile
log4j.appender.myAppender.recreate = 1
log4j.appender.myAppender.recreate_check_interval = 1
log4j.appender.myAppender.mode     = append
EOL

  # Create logfile
Log::Log4perl->init(\$conf3);
  # ... and immediately remove it
unlink $testfile;

print "sleeping for 2 secs\n";
sleep(2);

$logger = Log::Log4perl::get_logger('animal.dog');
$logger->info("test1");
open (LOG, $testfile) or die "can't open $testfile $!";
is(scalar <LOG>, "INFO - test1\n", "recreate before first write");

# ***************************************************************
# Check the 'recreate' feature with check_interval (2nd write)

trunc($testfile);
$conf3 = <<EOL;
log4j.category.animal.dog   = INFO, myAppender

log4j.appender.myAppender          = Log::Log4perl::Appender::File
log4j.appender.myAppender.layout   = Log::Log4perl::Layout::SimpleLayout
log4j.appender.myAppender.filename = $testfile
log4j.appender.myAppender.recreate = 1
log4j.appender.myAppender.recreate_check_interval = 1
log4j.appender.myAppender.mode     = append
EOL

  # Create logfile
Log::Log4perl->init(\$conf3);

  # Write to it
$logger = Log::Log4perl::get_logger('animal.dog');
$logger->info("test1");

  # ... remove it
unlink $testfile;

print "sleeping for 2 secs\n";
sleep(2);

  # ... write again
$logger->info("test2");

open (LOG, $testfile) or die "can't open $testfile $!";
is(scalar <LOG>, "INFO - test2\n", "recreate before 2nd write");

# ***************************************************************
# Check the 'recreate' feature with moved/recreated file

trunc($testfile);
$conf3 = <<EOL;
log4j.category.animal.dog   = INFO, myAppender

log4j.appender.myAppender          = Log::Log4perl::Appender::File
log4j.appender.myAppender.layout   = Log::Log4perl::Layout::SimpleLayout
log4j.appender.myAppender.filename = $testfile
log4j.appender.myAppender.recreate = 1
log4j.appender.myAppender.recreate_check_interval = 1
log4j.appender.myAppender.mode     = append
EOL

  # Create logfile
Log::Log4perl->init(\$conf3);

  # Get a logger, but dont write to it
$logger = Log::Log4perl::get_logger('animal.dog');

rename "$testfile", "$testfile.old" or die "Cannot rename ($!)";
  # recreate it
trunc($testfile);

print "sleeping for 2 secs\n";
sleep(2);

  # ... write to (hopefully) truncated file
$logger->info("test3");

open (LOG, $testfile) or die "can't open $testfile $!";
is(scalar <LOG>, "INFO - test3\n", "log to externally recreated file");

unlink "$testfile.old";
