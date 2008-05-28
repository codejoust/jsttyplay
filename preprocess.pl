#!/usr/bin/perl
use warnings;
use strict;
$| = 1;

my $coalesce_time = 0.05;

use Term::TtyRec;
use TermParser;
use FileHandle;
use Time::HiRes qw/ time sleep /;
use JSON;
use Carp;

$SIG{INT} = sub { confess };

sub openRec {
    my ($fn) = @_;
    my $fh = FileHandle->new($fn, "r") or die; # wtf.
    my $rec = Term::TtyRec->new($fh);
    return $rec;
}

{
    my $lasttime = undef;
    my @data = ();
    sub parseFrame {
        my ($rec, $term) = @_;
        local $_;
        while ( not @data or (defined $lasttime and $data[-1]->[0] - $lasttime < $coalesce_time) ) {
            my ($time, $data) = $rec->read_next;
            last unless defined $time;
            push @data, [$time, $data];
        }
        if ( @data > 1 ) {
            my $ld = pop @data;
            $term->parse($_) for map $_->[1], @data;
            $lasttime = $data[-1][0];
            @data = ($ld);
            return $lasttime;
        } elsif ( @data ) {
            $term->parse($_) for map $_->[1], @data;
            $lasttime = $data[-1][0];
            @data = ();
            return $lasttime;
        } else {
            return;
        }
    }
}

sub deltaFrame {
    my ($old, $new) = @_;
    my @old = split /\n/, $old;
    my @new = split /\n/, $new;
    die if @old != @new;
    my @diff;
    MAINROW: for my $row ( 0 .. $#old ) {
        if ( $new[$row] ne $old[$row] ) {
            for my $other ( 0 .. $#old ) {
                if ( $new[$row] eq $old[$other] ) {
                    # row copy mode
                    push @diff, ['cp', $other, $row];
                    next MAINROW;
                }
            }
            my $pickstart = undef;
            my $pickend = undef;
            for my $i ( 0 .. length($old[$row])-1 ) {
                if ( substr($old[$row], $i, 1) ne substr($new[$row], $i, 1) ) {
                    if ( not defined $pickstart ) {
                        $pickstart = $i;
                    } elsif ( defined $pickstart and not defined $pickend and $i - $pickstart == 1 ) {
                        $pickend = $i;
                    } elsif ( defined $pickstart and defined $pickend and $i - $pickend == 1 ) {
                        $pickend = $i;
                    } else {
                        undef $pickstart;
                        undef $pickend;
                        last;
                    }
                }
            }
            if ( defined $pickstart and defined $pickend ) {
                my $chunk = substr($new[$row], $pickstart, $pickend-$pickstart+1);
                if ( substr($chunk,0,1) x length($chunk) eq $chunk ) {
                    # one char chunk mode
                    push @diff, [$row, $pickstart, $pickend, ['a',substr($chunk,0,1)]];
                } else {
                    # chunk mode
                    push @diff, [$row, $pickstart, $pickend, $chunk];
                }
            } elsif ( defined $pickstart and not defined $pickend ) {
                # char mode
                push @diff, [$row, $pickstart, substr($new[$row], $pickstart, 1)];
            } else {
                if ( substr($new[$row],0,1) x length($new[$row]) eq $new[$row] ) {
                    # one char line mode
                    push @diff, [$row, ['a', substr($new[$row],0,1)]];
                } else {
                    # line mode
                    push @diff, [$row, $new[$row]];
                }
            }
        }
    }
    return \@diff;
}

sub compress_iframe {
    my (%do) = @_;
    for my $k ( keys %do ) {
        $do{$k} = compress_iframe_frame($do{$k});
    }
    return %do;
}

sub compress_iframe_frame {
    my ($v) = @_;
    my @rows = split /\n/, $v;
    my $lastrow = undef;
    my @out = ();
    for my $r ( @rows ) {
        if ( defined $lastrow and $lastrow eq $r ) {
            push @out, 'd';
        } else {
            if ( (substr($r,0,1) x length($r)) eq $r ) {
                push @out, ['a', substr($r,0,1)];
            } else {
                push @out, ['r', $r];
            }
        }
        $lastrow = $r;
    }
    return \@out;
}

###

print "setup\n";

my $width   = 80;
my $height  = 24;
my $term    = undef;
my $rec     = undef;
my $outfile = undef;

while ( @ARGV ) {
    my $ar = shift;
    if ( $ar eq "--width" or $ar eq "-w" ) {
        $width = shift;
    } elsif ( $ar eq "--height" or $ar eq "-h" ) {
        $height = shift;
    } elsif ( $ar eq "--size" or $ar eq "-s" ) {
        my $size = shift;
        my ($w,$h) = ($size =~ /^(\d+)x(\d+)$/);
        die "size argument is malformed, use WIDxHEI\n"
            unless defined $w and defined $h;
        $width = $w;
        $height = $h;
    } elsif ( not defined $rec ) {
        $rec = openRec($ar);
    } elsif ( not defined $outfile ) {
        die "won't overwrite an existing file $ar"
            if -e $ar;
        $outfile = $ar;
    } else {
        die "unknown argument or too many arguments: $ar\n";
    }
}

$term = TermParser->new( width => $width, height => $height );

my @timeline;

print "parse... 0 \033[K";

my %buffers = (
    d => ['as_string'],
    f => ['fg_as_string'],
    b => ['bg_as_string'],
    B => ['bold_as_string'],
    U => ['underline_as_string'],
);

my $lastx = undef;
my $lasty = undef;

for my $k ( keys %buffers ) {
    my $f = $buffers{$k}->[0];
    push @{$buffers{$k}}, $term->$f;
}

my $framect = 0;
my $starttime = undef;
while ( defined(my $time = parseFrame($rec, $term)) ) {
    my %new;
    for my $k ( keys %buffers ) {
        my $f = $buffers{$k}->[0];
        $new{$k} = $term->$f;
    }
    
    my %curpos = (
        x => $term->curposx+0,
        y => $term->curposy+0,
    );

    $starttime = $time unless defined $starttime;
    
    if ( $framect % 100 == 0 ) {
        push @timeline, { t => $time-$starttime, i => 1, %curpos, compress_iframe(%new) };
    } else {
        my %delta = map {+ $_ => deltaFrame($buffers{$_}[1], $new{$_}) } keys %new;
        for my $k ( keys %delta ) {
            delete $delta{$k} if @{$delta{$k}} == 0;
        }
        push @timeline, { t => $time-$starttime, %curpos, %delta };# if %delta;
    }
    
    $framect++;

    for my $k ( keys %buffers ) {
        $buffers{$k}->[1] = $new{$k};
    }
    
    print "\rparse... $framect \033[K";
}

print "\rparsed $framect frames\033[K\n";
print "serialize\n";

open my $sf, ">", $outfile or die "Couldn't open $outfile for writing: $!";
print $sf to_json { timeline => \@timeline, width => $width, height => $height };
close $sf;

print "done\n";
