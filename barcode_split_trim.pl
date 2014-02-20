#!/usr/bin/env perl
# barcode_split_trim.pl
# Mike Covington (Maloof Lab, UC-Davis)
# https://github.com/mfcovington/auto_barcode
# v1.3: 2012-11-09 - adds summary plotting and more fastq validation
# v1.2: 2012-10-03 - adds option to output stats (w/o creating fastq files)
# v1.1: 2012-09-25 - improvements to log
# v1.0: 2012-09-25
# v0.1: 2012-02-21
#
# Description:
# - Extracts fastq reads for specified barcode(s) from one or multiple FASTQ files
# - Writes helpful logs with barcode stats
use strict;
use warnings;
use autodie;
use feature 'say';
use Getopt::Long;
use File::Basename;
use File::Path 'make_path';
use List::Util qw(min max);
use Statistics::Descriptive;
use Statistics::R;
use Text::Table;

#TODO:
# incorporate more 'barcode_psychic.pl' functionality (warnings/suggestions)
# fuzzy matching

my $current_version = "v1.3";

#options/defaults
my ($barcode,    $id,     $expt_id, $list,
    $outdir,     $notrim, $stats,   $autoprefix,
    $autosuffix, $help,   $version
);
my $prefix  = "";
my $suffix  = "";
my $options = GetOptions(
    "barcode=s"  => \$barcode,
    "id=s"       => \$id,
    "expt_id=s"  => \$expt_id,
    "list"       => \$list,
    "outdir=s"   => \$outdir,
    "autoprefix" => \$autoprefix,
    "prefix=s"   => \$prefix,
    "suffix=s"   => \$suffix,
    "autosuffix" => \$autosuffix,
    "notrim"     => \$notrim,
    "stats"      => \$stats,
    "help"       => \$help,
    "version"    => \$version,
);
my @fq_files = grep { /f(ast)?q$/i } @ARGV;

validate_options( $version, $help, $barcode, $id, $list, $expt_id,
    \@fq_files );

my $barcode_table = get_barcodes( $list, $barcode, $id );

my $barcode_length = validate_barcodes($barcode_table);

my ( $directory, $filename, $unmatched_fh, $barcode_name )
    = open_fq_fhs_in_bulk( $barcode_table, \@fq_files, $outdir,
                           $prefix,        $suffix,    $autoprefix,
                           $autosuffix,    $barcode,   $stats );

my ( $total_matched, $total_unmatched, $barcodes_obs )
    = split_trim_barcodes( \@fq_files, $barcode_table, $barcode_length,
                           $notrim,    $stats );

close_fq_fhs( $barcode_table, $stats );

my $total_count = $total_matched + $total_unmatched;

summarize_observed_barcodes(
    $barcode_table, $barcodes_obs, $total_count,
    $directory,     $filename,     $barcode_name
);

summarize_counts(
    $barcode_table, \@fq_files, $total_count,
    $total_matched, $total_unmatched
);

plot_summary( $barcodes_obs, $barcode_table, $outdir, $expt_id );

exit;

sub percent {
    local $_ = shift;
    return sprintf( "%.1f", $_ * 100 ) . "%";
}

sub round {
    local $_ = shift;
    return int( $_ + 0.5 );
}

sub commify {
    local $_ = shift;
    1 while s/^([-+]?\d+)(\d{3})/$1,$2/;
    return $_;
}

sub validate_options {
    my ( $version, $help, $barcode, $id, $list, $expt_id, $fq_files ) = @_;

    die "$current_version\n" if $version;

    print_usage()
      and die "WARNING: To run successfully, remember to remove '--help'.\n"
      if $help;
    print_usage()
      and die "ERROR: Missing barcode or path to barcode file.\n"
      unless defined $barcode;
    print_usage()
      and die "ERROR: Missing sample ID or barcode list indicator ('--list').\n"
      unless defined $id
      or defined $list;
    print_usage()
      and die "ERROR: Missing Experiment ID ('--expt_id').\n"
      unless defined $expt_id;
    print_usage()
      and die "ERROR: Missing path to FASTQ file(s).\n"
      unless scalar $fq_files > 0;
}

sub print_usage {
    my $prog = basename($0);

    warn <<"EOF";

USAGE
  $prog [options] -b BARCODE IN.FASTQ

DESCRIPTION
  Extracts fastq reads for specified barcode(s) from one or multiple FASTQ files.
  Use wildcards ('*') to match multiple input FASTQ files.

OPTIONS
  -h, --help                 Print this help message
  -v, --version              Print version number
  -b, --barcode   BARCODE    Specify barcode or list of barcodes to extract
  -i, --id        SAMPLE_ID  Sample ID (not needed if using list of barcodes)
  -l, --list                 Indicates --barcode is a list of barcodes in a file
  -e, --expt_id   EXPT_ID    Experiment ID (used for summary plot)
  -n, --notrim               Split without trimming barcodes off
  -st, --stats               Output summary stats only (w/o creating fastq files)
  -o, --outdir    DIR        Output file is saved in the specified directory
                              (or same directory as IN.FASTQ, if --outdir is not used)

NAMING OPTIONS
  --autoprefix               Append FASTQ file name onto output
  --autosuffix               Append barcode onto output
  -p, --prefix    PREFIX     Add custom prefix to output
  -su, --suffix   SUFFIX     Add custom suffix to output

OUTPUT
  An output file in fastq format is written for each barcode to the directory
  containing IN.FASTQ, unless an output directory is specified.
  The default name of the output file is SAMPLE_ID.fq. The output names can be
  customized using the Naming Options.

EXAMPLES
  $prog -b GACTG -i Charlotte kitten_DNA.fq
  $prog --barcode barcode.file --list *_DNA.fastq
  $prog --help

EOF
}

sub get_barcodes {
    my ( $list, $barcode, $id ) = @_;

    my %barcode_table;
    if ($list) {
        open my $barcode_list_fh, '<', $barcode;
        %barcode_table =
          map {
            chomp;
            my @delim = split /\t/;
            ( $delim[0], { 'id' => $delim[1], 'count' => 0 } )
          } <$barcode_list_fh>;
        close $barcode_list_fh;
    }
    else { $barcode_table{$barcode} = [ $id, 0 ]; }

    return \%barcode_table;
}

sub validate_barcodes {
    my $barcode_table = shift;

    my $min_length = min map { length } keys $barcode_table;
    my $max_length = max map { length } keys $barcode_table;
    die
      "Unexpected variation in barcode length (min=$min_length, max=$max_length)\n"
      unless $min_length == $max_length;
    my $barcode_length = $max_length;
    map { die "Invalid barcode found: $_\n" unless /^[ACGT]{$barcode_length}$/i }
      keys $barcode_table;

    return $barcode_length;
}

sub open_fq_fhs_in_bulk {
    my ($barcode_table, $fq_files, $outdir,
        $prefix,        $suffix,   $autoprefix,
        $autosuffix,    $barcode,  $stats
    ) = @_;

    #open all fastq output filehandles
    my ( $filename, $directory, $filesuffix )
        = fileparse( $$fq_files[0], ".f(ast)?q" );
    $filename  = "multi_fq"    if @$fq_files > 1;
    $directory = $outdir . "/" if defined $outdir;
    make_path($directory);
    $prefix .= "." unless $prefix eq "";
    $suffix = "." . $suffix unless $suffix eq "";
    $prefix = join ".", $filename, $prefix if $autoprefix;
    my $barcode_name = fileparse($barcode);
    my $unmatched_fq_out
        = $directory
        . "unmatched."
        . $prefix . "fq_"
        . $filename . ".bar_"
        . $barcode_name
        . $suffix . ".fq";
    open my $unmatched_fh, ">", $unmatched_fq_out unless $stats;

    unless ($stats) {
        for ( keys $barcode_table ) {
            my $temp_suffix = $suffix;
            $temp_suffix = join ".", $suffix, $_ if $autosuffix;
            my $fq_out
                = $directory
                . $prefix
                . $$barcode_table{$_}->{id}
                . $temp_suffix . ".fq";
            open $$barcode_table{$_}->{fh}, ">", $fq_out;
        }
    }

    return $directory, $filename, $unmatched_fh, $barcode_name;
}

sub split_trim_barcodes {
    my ( $fq_files, $barcode_table, $barcode_length, $notrim, $stats ) = @_;

    #split and trim
    my $total_matched   = 0;
    my $total_unmatched = 0;
    my %barcodes_obs;
    for my $fq_in (@$fq_files) {
        open my $fq_in_fh, "<", $fq_in;
        while ( my $read_id = <$fq_in_fh> ) {
            my $seq     = <$fq_in_fh>;
            my $qual_id = <$fq_in_fh>;
            my $qual    = <$fq_in_fh>;

            die
              "Encountered sequence ID ($read_id) that doesn't start with '\@' on line $. of FASTQ file: $fq_in...\nInvalid or corrupt FASTQ file?\n"
              unless $read_id =~ /^@/;
            die
              "Encountered read ($read_id) with unequal sequence and quality lengths near line $. of FASTQ file: $fq_in...\nInvalid or corrupt FASTQ file?\n"
              unless length $seq == length $qual;

            my $cur_barcode = substr $seq, 0, $barcode_length;
            $barcodes_obs{$cur_barcode}++;
            if ( /^$cur_barcode/i ~~ %$barcode_table ) {
                $seq  = substr $seq, $barcode_length + 1 unless $notrim;
                $qual = substr $qual, $barcode_length + 1 unless $notrim;
                print { $$barcode_table{$cur_barcode}->{fh} }
                  $read_id . $seq . $qual_id . $qual
                  unless $stats;
                $$barcode_table{$cur_barcode}->{count}++;
                $total_matched++;
            }
            else {
                print $unmatched_fh $read_id . $seq . $qual_id . $qual
                  unless $stats;
                $total_unmatched++;
            }
        }
    }

    return $total_matched, $total_unmatched, \%barcodes_obs;
}

sub close_fq_fhs {
    my ( $barcode_table, $stats ) = @_;

    unless ($stats) {
        map { close $$barcode_table{$_}->{fh} } keys $barcode_table;
        close $unmatched_fh;
    }
}

sub summarize_observed_barcodes {
    my ( $barcode_table, $barcodes_obs, $total_count, $directory, $filename, $barcode_name ) = @_;

    #observed barcodes summary
    my @sorted_barcodes_obs
        = map {
        [   $_->[0],
            commify( $$barcodes_obs{ $_->[0] } ),
            percent( $$barcodes_obs{ $_->[0] } / ($total_count) ),
            $_->[2]->{id},
        ]
        }
        sort { $b->[1] <=> $a->[1] }
        map { [ $_, $$barcodes_obs{$_}, $$barcode_table{$_} ] }
        keys $barcodes_obs;
    open my $bar_log_fh, ">", $directory . join ".", "log_barcodes_observed",
        "fq_" . $filename, "bar_" . $barcode_name;
    my $tbl_observed = Text::Table->new(
        "barcode",
        "count\n&right",
        "percent\n&right",
        "id\n&right",
    );
    $tbl_observed->load(@sorted_barcodes_obs);
    print $bar_log_fh $tbl_observed;
    close $bar_log_fh;
}

sub summarize_counts {
    my ( $barcode_table, $fq_files, $total_count, $total_matched, $total_unmatched ) = @_;

    #counts summary
    my @barcode_counts =
      sort { $a->[0] cmp $b->[0] }
      map { [ $$barcode_table{$_}->{id}, $_, commify( $$barcode_table{$_}->{count} ), percent( $$barcode_table{$_}->{count} / $total_count ) ] }
      keys $barcode_table;

    open my $count_log_fh, ">", $directory . join ".", "log_barcode_counts", "fq_" . $filename, "bar_" . $barcode_name;
    say $count_log_fh "Barcode splitting summary for:";
    map { say $count_log_fh "  " . $_ } @$fq_files;
    my $max_fq_length = max map { length } @$fq_files;
    say $count_log_fh "-" x ( $max_fq_length + 2 );

    my $tbl_matched = Text::Table->new(
        "",
        "\n&right",
        "\n&right",
    );
    $tbl_matched->load(
        [
            "matched",
            commify($total_matched),
            percent( $total_matched / ( $total_matched + $total_unmatched ) ),
        ],
        [
            "unmatched",
            commify($total_unmatched),
            percent( $total_unmatched / ( $total_matched + $total_unmatched ) ),
        ],
    );

    print $count_log_fh $tbl_matched;
    say $count_log_fh "-" x ( $max_fq_length + 2 );

    my $stat = Statistics::Descriptive::Full->new();
    $stat->add_data( map{ $$barcode_table{$_}->{count} } keys $barcode_table );
    my $tbl_stats = Text::Table->new(
        "",
        "\n&num",
        "\n&right",
    );
    $tbl_stats->load(
        [ "barcodes", commify( $stat->count ) ],
        [ "min",      commify( $stat->min ),           percent( $stat->min / $total_count ) ],
        [ "max",      commify( $stat->max ),           percent( $stat->max / $total_count ) ],
        [ "mean",     commify( round( $stat->mean ) ), percent( round( $stat->mean ) / $total_count ) ],
        [ "median",   commify( $stat->median ),        percent( $stat->median / $total_count ) ],
    );
    print $count_log_fh $tbl_stats;
    say $count_log_fh "-" x ( $max_fq_length + 2 );

    my $tbl_counts = Text::Table->new(
        "id",
        "barcode",
        "count\n&right",
        "percent\n&right",
    );
    $tbl_counts->load(@barcode_counts);
    print $count_log_fh $tbl_counts;
    close $count_log_fh;
}

sub plot_summary {
    my ( $barcodes_obs, $barcode_table, $outdir, $expt_id ) = @_;

    my ( $barcode_data, $count_data, $match_data )
        = get_vectors( $barcodes_obs, $barcode_table );

    my $R = Statistics::R->new();

    $R->run(qq`setwd("$outdir")`);
    $R->run(qq`log <- data.frame(barcode = $barcode_data,
                                 count   = $count_data,
                                 matched = $match_data)`);

    my $plot_fxn = plot_function();

    $R->run($plot_fxn);
    $R->run(qq`barcode_plot(log, "$expt_id")`);
}

sub get_vectors {
    my ( $barcodes_obs, $barcode_table ) = @_;

    my @barcodes;
    my @counts;
    my @matches;
    my $barcodes;
    for my $barcode (keys $barcodes_obs) {
        push @barcodes, $barcode;
        push @counts, $$barcodes_obs{$barcode};
        my $match = exists $$barcode_table{$barcode} ? "matched" : "unmatched";
        push @matches, $match;
    }

    my $barcode_data = join ',', map {qq!"$_"!} @barcodes;
    my $count_data   = join ',', @counts;
    my $match_data   = join ',', map {qq!"$_"!} @matches;

    $_ = "c($_)" for $barcode_data, $count_data, $match_data;

    return $barcode_data, $count_data, $match_data;
}

sub plot_function {
    return <<EOF;    # Adapted from barcode_plot.R
        barcode_plot <- function(log.df, expt.name) {
          library("ggplot2")

          log.plot <-
            ggplot(
              data = log.df,
              aes(x = factor(matched), y = count / 1000000)) +
            geom_boxplot(outlier.size = 0) +
            geom_jitter() +
            ggtitle(label = expt.name) +
            xlab(label = "") +
            scale_y_continuous(name = "Count\n(million reads)")

          ggsave(
            filename = paste(sep = "", expt.name, ".barcodes.png"),
            plot     = log.plot,
            width    = 4,
            height   = 5
          )
        }
EOF
}
