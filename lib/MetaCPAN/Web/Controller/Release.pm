package MetaCPAN::Web::Controller::Release;
use strict;
use warnings;
use base 'MetaCPAN::Web::Controller';
use Scalar::Util qw(blessed);
use List::Util qw();

sub index {
    my ( $self, $req ) = @_;
    my $cv = AE::cv;
    my ( undef, undef, $author, $release ) = split( /\//, $req->path );
    my ( $out, $cond );
    if ( $author && $release ) {
        $cond = $self->get_release( $author, $release );
    } else {
        $cond = $self->find_release($author);
    }

    $cond = $cond->(
        sub {
            my ($data) = shift->recv;
            $out = $data->{hits}->{hits}->[0]->{_source};
            return $self->not_found($req) unless($out);
            ( $author, $release ) = ( $out->{author}, $out->{name} );
            my $modules = $self->get_modules( $author, $release );
            my $root   = $self->get_root_files( $author, $release );
            my $others = $self->get_others( $out->{distribution} );
            my $author = $self->get_author($author);
            return ( $modules & $others & $author & $root );
        } );

    $cond->(
        sub {
            my ( $modules, $others, $author, $root ) = shift->recv;
            if(blessed $modules && $modules->isa('Plack::Response')) {
                $cv->send($modules);
                return;  
            }
            $cv->send(
                {  release => $out,
                   author  => $author,
                   total   => $modules->{hits}->{total},
                   took    => List::Util::max($modules->{took}, $root->{took}, $author->{took}, $others->{took}),
                   root    => [
                             sort { $a->{name} cmp $b->{name} }
                             map  { $_->{fields} } @{ $root->{hits}->{hits} }
                   ],
                   others =>
                     [ map { $_->{fields} } @{ $others->{hits}->{hits} } ],
                   files => [
                       map {
                           {
                               %{ $_->{fields} },
                                 module => $_->{fields}->{'_source.module'},
                                 abstract => $_->{fields}->{'_source.abstract'}
                           }
                         } @{ $modules->{hits}->{hits} } ] } );
        } );

    return $cv;
}

sub get_modules {
    my ( $self, $author, $release ) = @_;
    $self->model->get(
         '/file/_search',
         { query  => { match_all => {} },
           filter => {
                and => [
                    { term => { release => $release } },
                    { term => { author  => $author } },
                    {
                      or => [
                           {
                             and => [
                                  { exists => { field => 'file.module.name' } },
                                  { term => { 'file.module.indexed' => \1 } } ]
                           },
                           { and => [
                               { exists => { field => 'documentation' } },
                               { term => { 'file.indexed' => \1 } }
                              ] } ]
                    } ]
           },
           size   => 999,
           sort   => ['documentation'],
           fields => [qw(documentation _source.abstract _source.module path status)],
         } );
}

sub find_release {
    my ( $self, $distribution ) = @_;
    $self->model->get(
             '/release/_search',
             { query  => { match_all => {} },
               filter => {
                    and => [
                        { term => { 'release.distribution' => $distribution } },
                        { term => { status                 => 'latest' } } ]
               },
               sort => [ { date => 'desc' } ],
               size => 1
             } );
}

sub get_root_files {
    my ( $self, $author, $release ) = @_;
    $self->model->get( '/file/_search',
                  {  query  => { match_all => {} },
                     filter => {
                                 and => [ { term => { release   => $release } },
                                          { term => { author    => $author } },
                                          { term => { level     => 0 } },
                                          { term => { directory => \0 } } ]
                     },
                     fields => [qw(name)],
                     size   => 100,
                  } );
}

sub get_others {
    my ( $self, $dist ) = @_;
    $self->model->get(
        '/release/_search',
        {  query  => { match_all => {} },
           filter => {
               and => [
                   { term => { 'release.distribution' => $dist } },
               ],

           },
           size   => 100,
           sort   => [ { date => 'desc' } ],
           fields => [qw(name date author version)],
        } );
}

1;
