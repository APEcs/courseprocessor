package ProcessorVersion;

use Exporter;
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw(get_version);

my $wiki2course = "1.15 (16 December 2010)";
my $processor   = "3.7RC1 (15 December 2010)";
my $release     = "3.7.0";

sub get_version {
    my $mode = shift;

    if(lc($mode) eq "processor") {
        return "Processor $processor [Toolchain version $release]";
    } elsif(lc($mode) eq "wiki2course") {
        return "Wiki export tool $processor [Toolchain version $release]";
    } else {
        return "Unknown mode";
    }
}

1;
