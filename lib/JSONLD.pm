=head1 NAME

JSONLD - A toolkit for interacting with JSON-LD data.

=head1 VERSION

This document describes JSONLD version 0.000_02

=head1 SYNOPSIS

  use v5.14;
  use JSON;
  use JSONLD;
  
  my $infile = 'test.jsonld';
  open(my $fh, '<', $infile) or die $!;
  my $content	= do { local($/); <$fh> };
  my $data = JSON->new()->boolean_values(0, 1)->decode($content);
  
  my $jld = JSONLD->new();
  my $expanded	= $jld->expand($data);

=head1 DESCRIPTION

This module implements part of the JSON-LD 1.1 standard for manipulating JSON data as
linked data.

=head1 METHODS

=over 4

=cut

package JSONLD {
	use v5.18;
	use autodie;
	our $VERSION	= '0.000_02';
	use utf8;
	use Moo;
	use LWP;
	use List::Util qw(all any);
	use JSON;
	use JSON qw(decode_json);
	use IRI;
	use FindBin qw($Bin);
	use File::Spec;
	use File::Glob qw(bsd_glob);
	use Encode qw(encode);
	use Debug::ShowStuff qw(indent println);
	use Data::Dumper;
	use Clone 'clone';
	use Carp qw(confess);
	use B qw(svref_2object SVf_IOK SVf_POK);
	use namespace::clean;
	
	has 'base_iri' => (is => 'rw', required => 0, default => sub { IRI->new('http://example.org/') });
	has 'processing_mode' => (is => 'ro', default => 'json-ld-1.1');
	has 'max_remote_contexts' => (is => 'rw', default => 10);
	has 'parsed_remote_contexts' => (is => 'rw', default => sub { +{} });
	has 'rdf_direction' => (is => 'rw');
	has 'identifier_map' => (is => 'rw', default => sub { +{} });
	has 'next_identifier_id' => (is => 'rw', default => 0);
	
	our $debug		= 0;
	my %keywords	= map { $_ => 1 } qw(: @base @container @context @direction @graph @id @import @included @index @json @language @list @nest @none @prefix @propagate @protected @reverse @set @type @value @version @vocab);
	
=item C<< expand( $data, [expandContext => $ctx] ) >>

Returns the JSON-LD expansion of C<< $data >>.

=cut

	sub expand {
		my $self	= shift;
		my $d		= shift;
		my %args	= @_;
		
		my $ctx		= {
			'@base' => $self->base_iri->abs, # TODO: not sure this follows the spec, but it's what makes test t0089 pass
		};
		if (my $ec = $args{expandContext}) {
			if (ref($ec) eq 'HASH' and exists $ec->{'@context'}) {
				$ec	= $ec->{'@context'};
			}
			$ctx	= $self->_4_1_2_ctx_processing($ctx, $ec);
		}
# 		warn "Expanding...";
		return $self->_expand($ctx, undef, $d);
	}
	
	sub _is_string {
		my $v	= shift;
		return 0 unless defined($v);
		return 0 if ref($v);
		my $sv	= svref_2object(\$v);
		my $flags	= $sv->FLAGS;
		my $is_string	= $flags & SVf_POK;
		return $is_string;
	}
	
	sub _expand {
		my $self	= shift;
		my $ctx		= shift // {};
		my $prop	= shift;
		my $d		= shift;
		my $v	= $self->_5_1_2_expansion($ctx, $prop, $d, @_);
		return $v;
	}
	
	sub _is_abs_iri {
		my $self	= shift;
		my $value	= shift;
		return 0 unless (length($value));
		my $i		= eval { IRI->new($value) };
		unless ($i) {
			return 0;
		}
		my $is_abs = (defined($i->scheme) and $value eq $i->abs);
		return $is_abs;
	}
	
	sub _is_iri {
		my $self	= shift;
		my $value	= shift;
		my $i		= eval { IRI->new(value => $value) };
		my $err		= $@;
		my $is_iri	= not($@);
		if ($@) {
			Carp::confess $@;
		}
		return $is_iri;
	}
	
	sub _load_document {
		my $self	= shift;
		my $url		= shift;
		my $profile	= shift;
		my $req_profile	= shift;
		my $ua		= LWP::UserAgent->new();
		my $resp	= $ua->get($url);
		return $resp;
	}
	
	sub _cm_contains {
		my $self	= shift;
		my $container_mapping	= shift;
		my $value	= shift;
		if (ref($container_mapping)) {
			Carp::cluck unless (ref($container_mapping) eq 'ARRAY');
			foreach my $m (@$container_mapping) {
				return 1 if ($m eq $value);
			}
		} else {
			return (defined($container_mapping) and $container_mapping eq $value);
		}
	}
	
	sub _cm_contains_any {
		my $self	= shift;
		my $container_mapping	= shift;
		my @values	= @_;
		foreach my $value (@values) {
			return 1 if ($self->_cm_contains($container_mapping, $value));
		}
		return 0;
	}
	
	sub _ctx_term_defn {
		my $self	= shift;
		my $ctx		= shift;
		my $term	= shift;
		confess "Bad context type in _ctx_term_defn: " . ref($ctx) unless (ref($ctx) eq 'HASH');
		no warnings 'uninitialized';
		return $ctx->{'terms'}{$term};
	}

	sub _ctx_contains_protected_terms {
		my $self	= shift;
		my $ctx		= shift;
		foreach my $term (keys %{ $ctx->{'terms'} }) {
			return 1 if $ctx->{'terms'}{$term}{'protected'};
		}
		return 0;
	}
	
	sub _is_node_object {
		my $self	= shift;
		my $value	= shift;
		return 0 unless (ref($value) eq 'HASH');
		foreach my $p (qw(@value @list @set)) {
			return 0 if (exists $value->{$p});
		}
		# TODO: check that value "is not the top-most map in the JSON-LD document consisting of no other entries than @graph and @context."
		return 1;
	}
	
	sub _is_value_object {
		my $self	= shift;
		my $value	= shift;
		return 0 unless (ref($value) eq 'HASH');
		return (exists $value->{'@value'});
	}

	sub _is_default_object {
		my $self	= shift;
		my $value	= shift;
		return 0 unless (ref($value) eq 'HASH');
		return (exists $value->{'@default'});
	}

	sub _is_list_object {
		my $self	= shift;
		my $value	= shift;
		return 0 unless (ref($value) eq 'HASH');
		return (exists $value->{'@list'});
	}
	
	sub _is_graph_object {
		my $self	= shift;
		my $value	= shift;
		return 0 unless (ref($value) eq 'HASH');
		return (exists $value->{'@graph'});
	}
	
	sub _4_1_2_ctx_processing {
		println "ENTER    =================> _4_1_2_ctx_processing" if $debug;
		my $__indent	= indent();
		my $self		= shift;
		my $activeCtx	= shift;
		my $localCtx	= shift;
		local($Data::Dumper::Indent)	= 0;
		println(Data::Dumper->Dump([$activeCtx], ['*activeCtx'])) if $debug;
		println(Data::Dumper->Dump([$localCtx], ['*localCtx'])) if $debug;
		my %args		= @_;
		my $propagate	= $args{propagate} // 1;
		my $remote_contexts	= $args{remote_contexts} // [];
		my $override_protected	= $args{override_protected} // 0;
		my $base_iri	= $args{base_iri} // $self->base_iri->abs;

		println "1" if $debug;
		my $result	= clone($activeCtx); # 1
		confess "Bad active context type in _4_1_2_ctx_processing: " . Dumper($activeCtx) unless (ref($activeCtx) eq 'HASH');
		if (ref($localCtx) eq 'HASH' and exists $localCtx->{'@propagate'}) {
			println "2" if $debug;
			$propagate	= ($localCtx->{'@propagate'} eq 'true'); # 2
		}
		
		if (not($propagate) and not exists $result->{'previous_context'}) {
			println "3" if $debug;
			$result->{'previous_context'}	= $activeCtx; # 3
		}
		
		if (ref($localCtx) ne 'ARRAY') {
			println "4" if $debug;
			$localCtx = [$localCtx]; # 4
		}
		
		println "5" if $debug;
		foreach my $context (@$localCtx) {
			my $__indent	= indent();
			println '-----------------------------------------------------------------' if $debug;
			println "5 loop for each local context item" if $debug;
			println(Data::Dumper->Dump([$context], ['*context'])) if $debug;
			if (not(defined($context))) {
				# 5.1
				println "5.1" if $debug;
				if (not($override_protected) and $self->_ctx_contains_protected_terms($activeCtx)) {
					println "5.1.1" if $debug;
					die 'invalid context nullification'; # 5.1.1
				} else {
					println "5.1.2 moving to next context" if $debug;
					my $prev	= $result;
					$result	= {};
					if ($propagate) {
						$result->{'previous_context'}	= $prev;
					}
					next;
				}
			}

			if (not(ref($context))) {
				println "5.2 $context" if $debug;
				
				println "5.2.1" if $debug;
				$context	= IRI->new(value => $context, base => $base_iri)->abs;
				
				if (scalar(@$remote_contexts) > $self->max_remote_contexts) {
					println "5.2.2" if $debug;
					die 'context overflow';
				}
				
				my $context_url		= $context;
				if (my $c = $self->parsed_remote_contexts->{$context}) {
					println "5.2.3" if $debug;
					$context	= $c;
				} else {
					println "5.2.4 loading context from: $context_url" if $debug;
					my $resp	= $self->_load_document($context_url, 'http://www.w3.org/ns/json-ld#context', 'http://www.w3.org/ns/json-ld#context');
					if (not $resp->is_success) {
						println "5.2.5 " . $resp->status_line if $debug;
						die 'loading remote context failed';
					}
					my $content	= $resp->decoded_content;
					$context		= eval { decode_json(encode('UTF-8', $content))->{'@context'} };
					if ($@) {
						println "5.2.5 $@" if $debug;
						die 'loading remote context failed';
					}
					$self->parsed_remote_contexts->{$context_url}	= $context;
				}

				println "5.2.6" if $debug;
				$result	= $self->_4_1_2_ctx_processing($result, $context, remote_contexts => clone($remote_contexts), base_iri => $context_url);

				println "5.2.7 moving to next context" if $debug;
				next;
			}

			if (ref($context) ne 'HASH') {
				println "5.3" if $debug;
				die "invalid_local_context"; # 5.3
			}
			
			println "5.4" if $debug; # no-op

			if (exists $context->{'@version'}) {
				println "5.5" if $debug;
				my $v	= $context->{'@version'};
				if ($v ne '1.1') {
					println "5.5.1" if $debug;
					die 'invalid @version value'; # 5.5.1
				}
				if ($self->processing_mode eq 'json-ld-1.0') {
					println "5.5.2" if $debug;
					die 'processing mode conflict';
				}
			}

			if (exists $context->{'@import'}) {
				println "5.6" if $debug;
				if ($self->processing_mode eq 'json-ld-1.0') {
					println "5.6.1" if $debug;
					die 'invalid context entry';
				}
				
				my $value	= $context->{'@import'};
				if (ref($value)) {
					println "5.6.2" if $debug;
					die 'invalid @import value';
				}
				
				println "5.6.3" if $debug;
				my $import	= IRI->new(value => $value, base => $self->base_iri)->abs;
				
				println "5.6.4 loading $import" if $debug;
				my $resp	= $self->_load_document($import, 'http://www.w3.org/ns/json-ld#context', 'http://www.w3.org/ns/json-ld#context');
				
				if (not $resp->is_success) {
					println "5.6.5" if $debug;
					die 'loading remote context failed';
				}
				
				my $content	= $resp->decoded_content;
				my $j		= eval { decode_json(encode('UTF-8', $content))->{'@context'} };
				if ($@) {
					println "5.6.5 $@" if $debug;
					die 'loading remote context failed';
				}
				
				unless (ref($j) eq 'HASH') {
					println "5.6.6" if $debug;
					die 'invalid remote context';
				}
				my $import_context	= $j;
				
				if (exists $import_context->{'@import'}) {
					println "5.6.7" if $debug;
					die 'invalid context entry';
				}
				
				println "5.6.8" if $debug;
				%$context	= (%$import_context, %$context);
			}
			
			if (exists $context->{'@base'} and scalar(@$remote_contexts) == 0) {
				println "5.7" if $debug;
				println "5.7.1" if $debug;
				my $value	= $context->{'@base'};
				println(Data::Dumper->Dump([$result], ['result'])) if $debug;
				
				if (not defined($value)) {
					println "5.7.2" if $debug;
					delete $result->{'@base'};
				} elsif ($self->_is_abs_iri($value)) {
					println "5.7.3 " . Data::Dumper->Dump([$value], ['base']) if $debug;
					$result->{'@base'}	= $value;
				} elsif ($self->_is_iri($value) and defined($result->{'@base'})) {
					println "5.7.4" if $debug;
					my $base	= IRI->new($result->{'@base'});
					my $i	= IRI->new(value => $value, base => $base);
					$result->{'@base'}	= $i->abs;
				} else {
					println "5.7.5" if $debug;
					die 'invalid base IRI';
				}
			}
			
			if (exists $context->{'@vocab'}) {
				println "5.8" if $debug;
				println "5.8.1" if $debug;
				my $value	= $context->{'@vocab'}; # 5.8.1
				if (not defined($value)) {
					println "5.8.2" if $debug;
					delete $result->{'@vocab'}; # 5.8.2
				} elsif ($value =~ /^_/ or $self->_is_iri($value)) {
					println "5.8.3" if $debug;
					my $iri	= $self->_5_2_2_iri_expansion($result, $value, vocab => 1, documentRelative => 1);
					$result->{'@vocab'}	= $iri;
				}
			}
			
			if (exists $context->{'@language'}) {
				println "5.9" if $debug;
				println "5.9.1 language = " . $context->{'@language'} if $debug;
				my $value	= $context->{'@language'};
				
				if (not defined($value)) {
					println "5.9.2" if $debug;
					delete $result->{'@language'};
				} elsif (_is_string($value)) {
					println "5.9.3 value is a string" if $debug;
					$result->{'@language'}	= $value;
					# TODO: validate language tag against BCP47
				} else {
					println "5.9.3 value is NOT a string" if $debug;
					die 'invalid default language';
				}
			}
			
			if (exists $context->{'@direction'}) {
				println "5.10" if $debug;
				if ($self->processing_mode eq 'json-ld-1.0') {
					println "5.10.1" if $debug;
					die 'invalid context entry';
				}
				
				println "5.10.2" if $debug;
				my $value	= $context->{'@direction'};
				
				if (not defined($value)) {
					println "5.10.3" if $debug;
					delete $result->{'@direction'};
				} elsif (not ref($value)) {
					println "5.10.4 \@direction = $value" if $debug;
					if ($value ne 'ltr' and $value ne 'rtl') {
						die 'invalid base direction';
					}
					$result->{'@direction'}	= $value;
				}
			}
			
			if (exists $context->{'@propagate'}) {
				println "5.11" if $debug;
				if ($self->processing_mode eq 'json-ld-1.0') {
					println "5.11.1" if $debug;
					die 'invalid context entry';
				}
				
				my $p	= $context->{'@propagate'};
				if ($p ne '1' and $p ne '0') { # boolean true or false
					println "5.11.2" if $debug;
					die 'invalid @propagate value';
				}
				
				println "5.11.3" if $debug;
			}
			
			println "5.12" if $debug;
			my $defined	= {}; # 5.12
			
			my @keys	= reverse sort grep { $_ !~ /^[@](base|direction|import|language|propagate|protected|version|vocab)$/ } keys %$context;
			println "5.13" if $debug;
			foreach my $key (@keys) {
				my $__indent	= indent();
				println "5.13 [$key]" if $debug;
				my $value	= $context->{$key};
				$self->_4_2_2_create_term_definition($result, $context, $key, $defined, protected => $context->{'@protected'}, propagate => $propagate, base_iri => $base_iri); # 5.13
			}
		}

		local($Data::Dumper::Indent)	= 1;
		println "6 returning from _4_1_2_ctx_processing with " . Data::Dumper->Dump([$result], ['final_context']) if $debug;
		return $result; # 6
	}
		
	sub _4_2_2_create_term_definition {
		my $self	= shift;
		my $activeCtx	= shift;
		my $localCtx	= shift;
		my $term		= shift;
		my $defined		= shift // {};
		println "ENTER    =================> _4_2_2_create_term_definition('$term')" if $debug;
		my $__indent	= indent();
		local($Data::Dumper::Indent)	= 0;
		println(Data::Dumper->Dump([$activeCtx], ['*activeCtx'])) if $debug;
		println(Data::Dumper->Dump([$localCtx], ['*localCtx'])) if $debug;
		println(Data::Dumper->Dump([$defined], ['*defined'])) if $debug;
		my %args		= @_;
		my $protected	= $args{protected} // 0;
		my $override_protected	= $args{override_protected} // 0;
		my $propagate	= $args{propagate} // 1;
		my $base_iri	= $args{base_iri} // $self->base_iri->abs;
		
		# 4.2.2
		if (exists ($defined->{$term})) {
			# 1
			println "1" if $debug;
			if ($defined->{$term}) {
				println "returning from _4_2_2_create_term_definition: term definition has already been created\n" if $debug;
				return;
			} elsif (exists $defined->{$term}) {
				die "cyclic IRI mapping";
			}
		}
		
		println "2 [setting defined{$term} = 0]" if $debug;
		$defined->{$term}	= 0; # 2

		println "3" if $debug;
		my $value	= clone($localCtx->{$term}); # 3
		println "3 " . Data::Dumper->Dump([$value], ['value']) if $debug;
		
		# NOTE: the language interaction between 4 and 5 here is a mess. Unclear what "Otherwise" applies to. Similarly with the "Otherwise" that begins 7 below.
		if ($self->processing_mode eq 'json-ld-1.1' and $term eq '@type') {
			# 4
			println "4" if $debug;
			unless (ref($value) eq 'HASH') {
				die 'keyword redefinition';
			}
			my @keys	= grep { $_ ne '@protected' } keys %$value;
			die 'keyword redefinition' unless (scalar(@keys) == 1 and $keys[0] eq '@container');
			die 'keyword redefinition' unless ($value->{'@container'} eq '@set');
		} else {
			# 5
			println "5" if $debug;
			if (exists $keywords{$term}) {
				println "5 keyword redefinition: $term" if $debug;
				die 'keyword redefinition';
			}
			if ($term =~ /^@[A-Za-z]+$/) {
				# https://www.w3.org/2018/json-ld-wg/Meetings/Minutes/2019/2019-09-20-json-ld#section5-2
				warn "create term definition attempted on a term that looks like a keyword: $term\n";
				println "5 returning so as to ignore a term that has the form of a keyword: $term" if $debug;
				return;
			}
		}
		
		println "6" if $debug;
		my $previous_defn	= $self->_ctx_term_defn($activeCtx, $term); # 6
		delete $activeCtx->{'terms'}{$term}; # https://github.com/w3c/json-ld-api/issues/176#issuecomment-545167708

		my $simple_term;
		if (not(defined($value))) {
			println "7" if $debug;
			$value	= {'@id' => undef}; # 7
		} elsif (_is_string($value)) {
			# 8
			println "8 value = {'\@id' => $value}" if $debug;
			$value	= {'@id' => $value};
			$simple_term	= 1;
		} elsif (ref($value) eq 'HASH') {
			println "9" if $debug;
			$simple_term	= 0; # 9
		} else {
			println "9" if $debug;
			die "invalid_term_definition"; # 9
		}
		
		println "10" if $debug;
		my $definition	= {'__source_base_iri' => $base_iri};	# 10
		
		if ($value->{'@protected'}) {
			println "11" if $debug;
			$definition->{'protected'}	= 1; # 11
			println "11 TODO processing mode of json-ld-1.0" if $debug;
		} elsif (not exists $value->{'@protected'} and $protected) {
			println "12" if $debug;
			$definition->{'protected'}	= 1; # 12
		}

		if (exists $value->{'@type'}) {
			# 13
			println "13" if $debug;
			my $type	= $value->{'@type'}; # 13.1
			if (ref($type)) {
				println "13.1" if $debug;
				die "invalid_type_mapping"; # 13.1
			}
			
			println "13.2" if $debug;
			$type	= $self->_5_2_2_iri_expansion($activeCtx, $type, vocab => 1, localCtx => $localCtx, 'defined' => $defined); # 13.2
			println(Data::Dumper->Dump([$type], ['type'])) if $debug;

			if (($type eq '@json' or $type eq '@none') and $self->processing_mode eq 'json-ld-1.0') {
				# https://github.com/w3c/json-ld-api/issues/259
				println "13.3 " . Data::Dumper->Dump([$type], ['*type']) if $debug;
				die 'invalid type mapping';
			}
			
			if ($type ne '@id' and $type ne '@vocab' and $type ne '@none' and $type ne '@json' and not($self->_is_abs_iri($type))) {
				# TODO: handle case "nor, if processing mode is json-ld-1.1, @json nor @none"
				println "13.4 " . Data::Dumper->Dump([$type], ['*type']) if $debug;
				die 'invalid type mapping'; # 13.4
			}
			
			println "13.5" if $debug;
			$definition->{'type_mapping'}	= $type; # 13.5
		}
		
		if (exists $value->{'@reverse'}) {
			# 14
			println "14" if $debug;
			if (exists $value->{'@id'} or exists $value->{'@nest'}) {
				println "14.1" if $debug;
				die 'invalid reverse property'; # 14.1
			}
			my $reverse	= $value->{'@reverse'};
			if (ref($reverse)) {
				println "14.2" if $debug;
				die 'invalid IRI mapping'; # 14.2
			}
			if ($reverse =~ /^@[A-Za-z]+$/) {
				println "14.3" if $debug;
				die '@reverse value looks like a keyword: ' . $reverse; # 14.3
			} else {
				 # 14.4
				println "14.4" if $debug;
				my $m	= $self->_5_2_2_iri_expansion($activeCtx, $reverse, vocab => 1, localCtx => $localCtx, 'defined' => $defined);
				if (not($self->_is_abs_iri($m)) and $m !~ /^:/) {
					die 'invalid IRI mapping';
				}
				$definition->{'iri_mapping'}	= $m;
			}
			
			if (exists $value->{'@container'}) {
				# 14.5
				println "14.5" if $debug;
				my $c	= $value->{'@container'};
				if ($c ne '@set' and $c ne '@index' and not(defined($c))) {
					die 'invalid reverse property';
				}
				$definition->{'container_mapping'}	= $c;
			}
			
			println "14.6" if $debug;
			$definition->{'reverse'}	= 1; # 14.6
			
			# 14.7
			println "14.7 [setting defined{$term} = 1]" if $debug;
			$activeCtx->{'terms'}{$term}	= $definition;
			$defined->{$term}	= 1;
			local($Data::Dumper::Indent)	= 0;
			println "returning from _4_2_2_create_term_definition: " . Dumper($activeCtx->{'terms'}{$term}) if $debug;
			return;
		}

		println "15" if $debug;
		$definition->{'reverse'}	= 0; # 15
		
		if (exists $value->{'@id'} and $value->{'@id'} ne $term) {
			# 16
			println "16" if $debug;
			if (not defined($value->{'@id'})) {
				println "16.1" if $debug;
			} else {
				println "16.2" if $debug;
				my $id	= $value->{'@id'};
					if (not _is_string($id)) {
						println "16.2.1" if $debug;
						die 'invalid IRI mapping'; # 16.2
					}
			
					if (defined($id) and not exists $keywords{$id} and $id =~ /^@[A-Za-z]+$/) {
						println "16.2.2" if $debug;
						warn "create term definition encountered an \@id that looks like a keyword: $id\n";
						return;
					} else {
						println "16.2.3" if $debug;
						my $iri	= $self->_5_2_2_iri_expansion($activeCtx, $id, vocab => 1, localCtx => $localCtx, 'defined' => $defined);
						if (not exists $keywords{$iri} and not $self->_is_abs_iri($iri) and $iri !~ /:/) {
							die 'invalid IRI mapping';
						}
						if ($iri eq '@context') {
							die 'invalid keyword alias';
						}
						$definition->{'iri_mapping'}	= $iri;
					}
					if ($term =~ /.:./ or index($term, '/') >= 0) {
						println "16.2.4" if $debug;
						println "16.2.4.1" if $debug;
						$defined->{$term}	= 1;

						my $iri	= $self->_5_2_2_iri_expansion($activeCtx, $term, vocab => 1, localCtx => $localCtx, 'defined' => $defined);
						if ($iri ne $definition->{'iri_mapping'}) {
							println "16.2.4.2" if $debug;
							die 'invalid IRI mapping'; # 16.5 ; NOTE: the text here doesn't discuss what parameters to pass to IRI expansion
						}
					}
			
					if ($term !~ m{[:/]} and $simple_term and $definition->{'iri_mapping'} =~ m{[][:/?#@]$}) {
						println "16.2.5" if $debug;
						$definition->{'prefix'}	= 1;
					}
	# 			}
			}
		} elsif ($term =~ /.:/) {
			# 17
			println "17" if $debug;
			my ($prefix, $suffix)	= split(/:/, $term, 2);
			if (exists $localCtx->{$prefix}) {
				println "17.1" if $debug;
				$self->_4_2_2_create_term_definition($activeCtx, $localCtx, $prefix, $defined); # 17.1
			}
			if (exists $activeCtx->{'terms'}{$prefix}) {
				println "17.2" if $debug;
				$definition->{'iri_mapping'}	= $activeCtx->{'terms'}{$prefix}{'iri_mapping'} . $suffix; # 17.2
			} else {
				println "17.3" if $debug;
				$definition->{'iri_mapping'}	= $term; # 17.3
			}
		} elsif ($term =~ m{/}) {
			# TODO: 18
			println "18 TODO"; # if $debug;
		} elsif ($term eq '@type') {
			println "19" if $debug;
			$definition->{'iri_mapping'}	= '@type'; # 19
		} else {
			# 20 ; NOTE: this section uses a passive voice "the IRI mapping of definition is set to ..." cf. 18 where it's active: "set the IRI mapping of definition to @type"
			if (exists $activeCtx->{'@vocab'}) {
				println "20" if $debug;
				$definition->{'iri_mapping'}	= $activeCtx->{'@vocab'} . $term;
			} else {
				println "20" if $debug;
				die 'invalid IRI mapping';
			}
		}
		
		if (exists $value->{'@container'}) {
			# TODO: 21
			println "21" if $debug;

			println "21.1" if $debug;
			my $container	= $value->{'@container'}; # 21.1

			# 21.1 error checking
			my %acceptable	= map { $_ => 1 } qw(@graph @id @index @language @list @set @type);
			if (exists $acceptable{$container}) {
			} elsif (ref($container) eq 'ARRAY') {
				if (scalar(@$container) == 1) {
					my ($c)	= @$container;
					unless (exists $acceptable{$c}) {
						println "21.1(a)" if $debug;
						die 'invalid container mapping';
					}
				} elsif (any { $_ =~ /^[@](id|index)$/ } @$container) { # any { $_ eq '@graph' } @$container
					
				} elsif (any { $_ eq '@set' } @$container and any { $_ =~ /^[@](index|graph|id|type|language)$/ } @$container) {
					
				} else {
					warn Dumper($container) if $debug;
					println "21.1(b)" if $debug;
					die 'invalid container mapping';
				}
			} else {
				println "21.1(c)" if $debug;
				die 'invalid container mapping';
			}
			
			if ($self->processing_mode eq 'json-ld-1.0') {
				if (any { $container eq $_ } qw(@graph @id @type) or ref($container)) {
					println "21.2" if $debug;
					die 'invalid container mapping';
				}
			}
			
			println "21.3" if $debug;
			if (ref($container) eq 'ARRAY') {
				$definition->{'container_mapping'}	= $container; # 21.3
			} else {
				$definition->{'container_mapping'}	= [$container]; # 21.3
			}
			
			if ($container eq '@type') {
				println "21.4" if $debug;
				if (not defined($definition->{'type_mapping'})) {
					println "21.4.1" if $debug;
					$definition->{'type_mapping'}	= '@id';
				}
				
				my $tm	= $definition->{'type_mapping'};
				if ($tm ne '@id' and $tm ne '@vocab') {
					println "21.4.2" if $debug;
					die 'invalid type mapping';
				}
			}
		}

		if (exists $value->{'@index'}) {
			println "22" if $debug;
			my $container_mapping	= $definition->{'container_mapping'};
			if ($self->processing_mode eq 'json-ld-1.0' or not $self->_cm_contains($container_mapping, '@index')) {
				println "22.1" if $debug;
				die 'invalid term definition';
			}

			println "22.2" if $debug;
			my $index	= $value->{'@index'};
			my $expanded	= $self->_5_2_2_iri_expansion($activeCtx, $index);
			unless ($self->_is_iri($expanded)) {
				die 'invalid term definition';
			}
			
			println "22.3" if $debug;
			$definition->{'index_mapping'}	= $index;
		}

		if (exists $value->{'@context'}) {
			println "23" if $debug;
			if ($self->processing_mode eq 'json-ld-1.0') {
				println "23.1" if $debug;
				die 'invalid term definition';
			}

			println "23.2" if $debug;
			my $context	= $value->{'@context'};

			println "23.3" if $debug;
			$self->_4_1_2_ctx_processing($activeCtx, $context, override_protected => 1, base_iri => $base_iri); # discard result
# 			$self->_4_1_2_ctx_processing($activeCtx, $context, override_protected => 1); # discard result
			
			$definition->{'@context'}	= $context;	# Note: not sure about the spec text wording here: "Set the local context of definition to context." What is the "local context" of a definition?
		}

		if (exists $value->{'@language'} and not exists $value->{'@type'}) {
			println "24" if $debug;
			println "24.1" if $debug;
			my $language	= $value->{'@language'};
			if (defined($language) and ref($language)) {
				die 'invalid language mapping';
			}
			# TODO: validate language tag against BCP47

			println "24.2" if $debug;
			# TODO: normalize language tag
			$definition->{'language_mapping'}	= $language;
		}

		if (exists $value->{'@direction'} and not exists $value->{'@type'}) {
			println "25" if $debug;
			my $direction	= $value->{'@direction'};

			println "25.1" if $debug;
			if (not(defined($direction))) {
			} elsif ($direction ne 'ltr' and $direction ne 'rtl') {
				die 'invalid base direction';
			}
			
			$definition->{'direction_mapping'}	= $direction;
		}

		if (exists $value->{'@nest'}) {
			println "26" if $debug;
			if ($self->processing_mode eq 'json-ld-1.0') {
				println "26.1" if $debug;
				die 'invalid term definition';
			}
			
			println "26.2" if $debug;
			my $nv	= $value->{'@nest'};
			if (not(defined($nv)) or ref($nv)) {
				die 'invalid @nest value';
			} elsif (exists $keywords{$nv} and $nv ne '@nest') {
				die 'invalid @nest value';
			}
			$definition->{'nest_value'}	= $nv;
		}

		if (exists $value->{'@prefix'}) {
			println "27" if $debug;
			if ($self->processing_mode eq 'json-ld-1.0' or $term =~ m{[:/]}) {
				println "27.1" if $debug;
				die 'invalid term definition'; # 27.1
			}
			
			println "27.2" if $debug;
			$definition->{'prefix'}	= $value->{'@prefix'};
			# TODO: check if this value is a boolean. if it is NOT, die 'invalid @prefix value';
			
			if ($definition->{'prefix'} and exists $keywords{$definition->{'iri_mapping'}}) {
				println "27.3" if $debug;
				die 'invalid term definition';
			}
		}

		my @keys	= grep { not m/^[@](id|reverse|container|context|language|nest|prefix|type|direction|protected|index)$/ } keys %$value;
		if (scalar(@keys)) {
			println "28 " . Data::Dumper->Dump([\@keys, $value], ['invalid_keys', 'value']) if $debug;
			die 'invalid term definition'; # 28
		}
		
		if (not($override_protected) and $previous_defn->{'protected'}) {
			# 29
			println "29" if $debug;
			my %cmp_a	= map { $_ => $definition->{$_} } grep { $_ ne 'protected' } keys %$definition;
			my %cmp_b	= map { $_ => $previous_defn->{$_} } grep { $_ ne 'protected' } keys %$previous_defn;
			my $j		= JSON->new->canonical(1);
			if ($j->encode(\%cmp_a) ne $j->encode(\%cmp_b)) {
				println "29.1" if $debug;
				die 'protected term redefinition'; # 29.1
			}
			println "29.2" if $debug;
			$definition	= $previous_defn; # 29.2
		}
		
		println "30 [setting defined{$term} = 1]" if $debug;
		println "30 setting term definition " . Data::Dumper->Dump([$definition], [$term]) if $debug;
		$activeCtx->{'terms'}{$term}	= $definition; # 30
		$defined->{$term}	= 1; # 30
		local($Data::Dumper::Indent)	= 0;
		println "returning from _4_2_2_create_term_definition: " . Dumper($activeCtx->{'terms'}{$term}) if $debug;
		return;
	}

	sub _5_1_2_expansion {
		my $self		= shift;
		my $activeCtx	= shift;
		my $activeProp	= shift;
		my $element		= shift;
		{
			no warnings 'uninitialized';
			println "ENTER    =================> _5_1_2_expansion('$activeProp')" if $debug;
		}
		my $__indent	= indent();
		local($Data::Dumper::Indent)	= 0;
		println(Data::Dumper->Dump([$activeCtx], ['activeCtx'])) if $debug;
		println(Data::Dumper->Dump([$activeProp], ['activeProp'])) if $debug;
		println(Data::Dumper->Dump([$element], ['element'])) if $debug;
		my %args		= @_;
		my $frameExpansion	= $args{frameExpansion} // 0;
		my $ordered		= $args{ordered} // 0;
		my $fromMap		= $args{fromMap} // 0;
		
		unless (defined($element)) {
			println "1 returning from _5_1_2_expansion: undefined element" if $debug;
			return; # 1
		}
		if (defined($activeProp) and $activeProp eq '@default') {
			println "2" if $debug;
			$frameExpansion = 0; # 2
		}
		
		my $property_scoped_ctx;
		my $tdef = $self->_ctx_term_defn($activeCtx, $activeProp);
		if ($tdef and my $lctx = $tdef->{'@context'}) {
			println "3 property-scoped context for property $activeProp" if $debug;
			$property_scoped_ctx	= $lctx; # 3
		}
		
		if (not(ref($element))) {
			# 4
			println "4" if $debug;
			if (not(defined($activeProp)) or $activeProp eq '@graph') {
				println "4.1 returning from _5_1_2_expansion: free floating scalar" if $debug;
				return; # 4.1
			}
			if (defined($property_scoped_ctx)) {
				println "4.2" if $debug;
				$activeCtx = $self->_4_1_2_ctx_processing($activeCtx, $property_scoped_ctx); # 4.2
				println "after 4.2: " . Data::Dumper->Dump([$activeCtx], ['activeCtx']) if $debug;
			}
			
			my $v	= $self->_5_3_2_value_expand($activeCtx, $activeProp, $element);
			local($Data::Dumper::Indent)	= 1;
			println "4.3 returning from _5_1_2_expansion with " . Data::Dumper->Dump([$v], ['expandedValue']) if $debug;
			return $v; # 4.3
		}
		
		if (ref($element) eq 'ARRAY') {
			# 5
			println "5" if $debug;
			my @result; # 5.1
			println "5.1" if $debug;
			foreach my $item (@$element) {
				# 5.2
				println "5.2" if $debug;
				println "5.2.1" if $debug;
				my $expandedItem	= $self->_5_1_2_expansion($activeCtx, $activeProp, $item); # 5.2.1
				println "5.2.1 expanded item = " . Dumper($expandedItem) if $debug;
				
				# NOTE: 5.2.2 "container mapping" is in the term definition for active property, right? The text omits the term definition reference.
				my $container_mapping	= $tdef->{'container_mapping'};
#				if (any { $_ eq '@list'} @$container_mapping and ref($expandedItem) eq 'ARRAY') {
				if ($self->_cm_contains($container_mapping, '@list')  and ref($expandedItem) eq 'ARRAY') {
					println "5.2.2" if $debug;
					$expandedItem	= { '@list' => $expandedItem }; # 5.2.2
				}
				
				# 5.2.3
				println "5.2.3" if $debug;
				if (ref($expandedItem) eq 'ARRAY') {
					push(@result, @$expandedItem);
				} elsif (defined($expandedItem)) {
					push(@result, $expandedItem);
				}
			}
			
			local($Data::Dumper::Indent)	= 1;
			println "5.3 returning from _5_1_2_expansion with " . Data::Dumper->Dump([\@result], ['expanded_array_value']) if $debug;
			return \@result; # 5.3
		}
		
		println "6" if $debug;
		die "Unexpected non-map encountered during expansion: $element" unless (ref($element) eq 'HASH'); # 6; assert

		if (my $prevCtx = $activeCtx->{'previous_context'}) {
			unless ($fromMap) {
				unless (exists $element->{'@value'}) {
					my @keys	= keys %$element;
					unless (scalar(@keys) == 1 and $keys[0] eq '@id') {
						println "7" if $debug;
						$activeCtx	= $prevCtx; # 7
					}
				}
			}
		}
		
		if (defined($property_scoped_ctx)) {
			println "8" if $debug;
			my %args;
			if ($tdef and exists $tdef->{'__source_base_iri'}) {
				$args{base_iri}	= $tdef->{'__source_base_iri'};
			}
			local($Data::Dumper::Indent)	= 1;
			println "before 8: " . Data::Dumper->Dump([$activeCtx, $property_scoped_ctx], [qw'activeCtx property_scoped_ctx']) if $debug;
			$activeCtx = $self->_4_1_2_ctx_processing($activeCtx, $property_scoped_ctx, %args); # 8
			println "after 8: " . Data::Dumper->Dump([$activeCtx], ['activeCtx']) if $debug;
		}
		
		if (exists $element->{'@context'}) {
			println "9" if $debug;
			my $c = $element->{'@context'};
			$activeCtx = $self->_4_1_2_ctx_processing($activeCtx, $c); # 9
		}
		
		println "10" if $debug;
		my $type_scoped_ctx	= clone($activeCtx); # 10
		
		println "11" if $debug;
		foreach my $key (sort keys %$element) {
			my $__indent	= indent();
			my $value	= $element->{$key};
			# 11
			println "11 [$key]" if $debug;
			unless ('@type' eq $self->_5_2_2_iri_expansion($activeCtx, $key, vocab => 1)) {
				println "[skipping key $key in search of \@type]" if $debug;
				next;
			}

			println "11 body [$key]" if $debug;
			
			unless (ref($value) eq 'ARRAY') {
				println "11.1 [$key]" if $debug;
				$value	= [$value]; # 11.1
			}
			
			foreach my $term (sort @$value) {
				println "11.2 attempting with [$term]" if $debug;
				if (not(ref($term))) {
					my $tdef	= $self->_ctx_term_defn($activeCtx, $term);
					if (my $c = $tdef->{'@context'}) {
						println "11.2" if $debug;
						$activeCtx	= $self->_4_1_2_ctx_processing($activeCtx, $c, propagate => 0);
						local($Data::Dumper::Indent)	= 1;
						println "11.2 " . Data::Dumper->Dump([$activeCtx], ['activeCtx']) if $debug;
					}
				}
			}
			
		}
		println "After 11, " . Data::Dumper->Dump([$element], ['element']) if $debug;
		
		println "12" if $debug;
		my $result	= {}; # 12a
		my $nests	= {}; # 12b
		my $input_type	= '';
		foreach my $key (sort keys %$element) {
			my $expandedKey	= $self->_5_2_2_iri_expansion($activeCtx, $key);
			if ($expandedKey eq '@type') {
				$input_type	= $self->_5_2_2_iri_expansion($activeCtx, $element->{$key});
				last;
			}
		}
		println "12 " . Data::Dumper->Dump([$input_type], ['*input_type']) if $debug;
		
		$self->_5_1_2_expansion_step_13($activeCtx, $type_scoped_ctx, $result, $activeProp, $input_type, $nests, $ordered, $frameExpansion, $element);
		println "after 13,14: " . Data::Dumper->Dump([$result], ['*result']) if $debug;

		if (exists $result->{'@value'}) {
			# 15
			println "15" if $debug;
			my @keys	= keys %$result;
			my %acceptable	= map { $_ => 1 } qw(@direction @index @language @type @value);
			foreach my $k (@keys) {
				unless ($acceptable{$k}) {
					println "15.1 [$k]" if $debug;
					die 'invalid value object' ; # 15.1
				}
			}
			if (exists $result->{'@language'} or exists $result->{'@direction'}) {
				println "15.1 \@language handling" if $debug;
				die 'invalid value object' if (exists $result->{'@type'}); # 15.1
			}
			
# 			if (not(defined($result->{'@value'}))) {
			if (defined($result->{'@type'}) and $result->{'@type'} eq '@json') {
				println "15.2" if $debug;
				# TODO: treat $result->{'@value'} as a JSON literal
			} elsif (not(defined($result->{'@value'})) or (ref($result->{'@value'}) eq 'ARRAY' and not scalar(@{$result->{'@value'}}))) { # based on irc conversation with gkellog
				println "15.3" if $debug;
				return undef;
			} elsif (ref($result->{'@value'}) and exists $result->{'@language'}) {
				println "15.4" if $debug;
				die 'invalid language-tagged value; ' . Dumper($result); # 15.4
			} elsif (exists $result->{'@type'} and not($self->_is_iri($result->{'@type'}))) {
				warn "Not an IRI \@type: " . Dumper($result->{'@type'});
				println "15.5" if $debug;
				die 'invalid typed value: ' . Dumper($result); # 15.5
# 			} elsif (exists $result->{'@type'}) {
# 				my $types	= $result->{'@type'};
# 				my @types	= (ref($types) eq 'ARRAY') ? @$types : $types;
# 				foreach my $t (@types) {
# 					unless ($self->_is_iri($t)) {
# 						warn "Not an IRI \@type: " . Dumper($result->{'@type'});
# 						println "15.5" if $debug;
# 						die 'invalid typed value: ' . Dumper($result); # 15.5
# 					}
# 				}
			}
			println "15 resulting in " . Data::Dumper->Dump([$result], ['*result']) if $debug;
		} elsif (exists $result->{'@type'} and ref($result->{'@type'}) ne 'ARRAY') {
			println "16" if $debug;
			$result->{'@type'}	= [$result->{'@type'}]; # 16
			println "16 resulting in " . Data::Dumper->Dump([$result], ['*result']) if $debug;
		} elsif (exists $result->{'@set'} or exists $result->{'@list'}) {
			# 17
			println "17" if $debug;
			my @keys	= grep { $_ ne '@set' and $_ ne '@list' } keys %$result;
			if (scalar(@keys)) {
				println "17.1" if $debug;
				die 'invalid set or list object' unless (scalar(@keys) == 1 and $keys[0] eq '@index'); # 17.1
			}
			if (exists $result->{'@set'}) {
				println "17.2" if $debug;
				$result	= $result->{'@set'}; # 17.2
			}
			println "17 resulting in " . Data::Dumper->Dump([$result], ['*result']) if $debug;
		}
		
		println "after 17 resulting in " . Data::Dumper->Dump([$result], ['*result']) if $debug;
		my @keys	= (ref($result) eq 'HASH') ? keys %$result : ();
		if (ref($result) eq 'HASH') { # NOTE: assuming based on the effects of 16.2 that this condition is necessary to guard against cases where $result is not a hashref.
			if (scalar(@keys) == 1 and $keys[0] eq '@language') {
				println "18" if $debug;
				return undef;
			}
			if (not(defined($activeProp)) or $activeProp eq '@graph') {
				# 19
				local($Data::Dumper::Indent)	= 0;
				println "19 " . Data::Dumper->Dump([$result], ['*result']) if $debug;
				if (ref($result) eq 'HASH' and scalar(@keys) == 0 or exists $result->{'@value'} or exists $result->{'@list'}) {
					println "19.1" if $debug;
					$result	= undef; # 19.1
				} elsif (ref($result) eq 'HASH' and scalar(@keys) == 1 and $keys[0] eq '@id') {
					unless ($frameExpansion) {
						println "19.2" if $debug;
						$result	= undef; # 19.2
					}
				}
			}
			println "19 resulting in " . Data::Dumper->Dump([$result], ['*result']) if $debug;
		}
		
		if (ref($result) eq 'HASH') {
			if (scalar(@keys) == 1 and $keys[0] eq '@graph') {
				println "20" if $debug;
				$result	= $result->{'@graph'};
			}
		}
		
		unless (defined($result)) {
			println "21" if $debug;
			$result	= [];
		}
		
		if (ref($result) ne 'ARRAY') {
			println "22" if $debug;
			$result	= [$result];
		}
		
		local($Data::Dumper::Indent)	= 1;
		println "23 returning from _5_1_2_expansion with final value " . Data::Dumper->Dump([$result], ['*result']) if $debug;
		return $result; # 19
	}
	
	sub _5_1_2_expansion_step_13 {
		my $self			= shift;
		my $activeCtx		= shift;
		my $type_scoped_ctx	= shift;
		my $result			= shift;
		my $activeProp		= shift;
		my $input_type		= shift;
		my $nests			= shift;
		my $ordered			= shift;
		my $frameExpansion	= shift;
		my $element			= shift;
		println "13 --- processing " . Data::Dumper->Dump([$element], ['element']) if ($debug);
		foreach my $key (sort keys %$element) {
			my $__indent	= indent();
			my $value	= $element->{$key};
			# 13
			println '-----------------------------------------------------------------' if $debug;
			println "13 [$key] " . Data::Dumper->Dump([$value], ['value']) if $debug;
			if ($key eq '@context') {
				println "13.1 going to next element key" if $debug;
				next; # 13.1
			}
			local($Data::Dumper::Indent)	= 1;
			println(Data::Dumper->Dump([$activeCtx], ['activeCtx'])) if $debug;
			
			println "13.2" if $debug;
			my $expandedProperty	= $self->_5_2_2_iri_expansion($activeCtx, $key, vocab => 1); # 13.2
			println "13.2 " . Data::Dumper->Dump([$expandedProperty], ['expandedProperty']) if $debug;
			println(Data::Dumper->Dump([$expandedProperty], ['expandedProperty'])) if $debug;
			if (not(defined($expandedProperty)) or ($expandedProperty !~ /:/ and not exists $keywords{$expandedProperty})) {
				println "13.3 going to next element key" if $debug;
				next; # 13.3
			}
		
			my $expandedValue;
			if (exists $keywords{$expandedProperty}) {
				# 13.4
				println "13.4 keyword: $expandedProperty" if $debug;
				
				if (defined($activeProp) and $activeProp eq '@reverse') {
					println "13.4.1" if $debug;
					die 'invalid reverse property map'; # 13.4.1
				}

				if (exists $result->{$expandedProperty}) {
					my $p	= $result->{$expandedProperty};
					if ($expandedProperty ne '@included' and $expandedProperty ne '@type') {
						println "13.4.2 colliding: $expandedProperty" if $debug;
						die 'colliding keywords'; # 13.4.2
					}
				}
				
				# NOTE: another case of an "Otherwise" applying to a partial conjunction
				if ($expandedProperty eq '@id') {
					println "13.4.3" if $debug;
					if (ref($value) or not defined($value)) {
						println "13.4.3.1 invalid" if $debug;
						die 'invalid @id value';
					} else {
						println "13.4.3.2" if $debug;
						$expandedValue	= $self->_5_2_2_iri_expansion($activeCtx, $value, documentRelative => 1);
						println "13.4.3.2 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
					}
				}

				if ($expandedProperty eq '@type') {
					println "13.4.4" if $debug;
					my $is_string = _is_string($value);
					my $is_array	= ref($value) eq 'ARRAY';
					my $is_array_of_strings	= ($is_array and all { not(ref($_)) } @$value);
					if (not($is_string) and not($is_array_of_strings)) {
						println "13.4.4.1 invalid" if $debug;
						die 'invalid type value';
					}
					
					if (ref($value) eq 'HASH' and scalar(%$value) == 0) {
						println "13.4.4.2" if $debug;
						$expandedValue	= $value;
						println "13.4.4.2 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
					} elsif ($self->_is_default_object($value)) {
						println "13.4.4.3" if $debug;
						$expandedValue	= { '@default' => $self->_5_2_2_iri_expansion($type_scoped_ctx, $value, vocab => 1, documentRelative => 1) };
						println "13.4.4.3 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
					} else {
						println "13.4.4.4" if $debug;
						if (ref($value)) {
							$expandedValue	= [map {$self->_5_2_2_iri_expansion($type_scoped_ctx, $_, vocab => 1, documentRelative => 1)} @$value];
						} else {
							$expandedValue	= $self->_5_2_2_iri_expansion($type_scoped_ctx, $value, vocab => 1, documentRelative => 1);
						}
						println "13.4.4.4 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
					}
					
					if (my $t = $result->{'@type'}) {
						println "13.4.4.5" if $debug;
						if (ref($expandedValue) ne 'ARRAY') {
							$expandedValue	= [$expandedValue];
						}
						unshift(@$expandedValue, $t);
						println "13.4.4.5 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
					}
				}

				if ($expandedProperty eq '@graph') {
					println "13.4.5" if $debug;
					my $v	= $self->_5_1_2_expansion($activeCtx, '@graph', $value, frameExpansion => $frameExpansion, ordered => $ordered);
					# TODO: ensure that expanded value is an array of one or more maps
					$expandedValue	= $v;
					println "13.4.5 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
				}

				if ($expandedProperty eq '@included') {
					println "13.4.6" if $debug;
					if ($self->processing_mode eq 'json-ld-1.0') {
						println "13.4.6.1" if $debug;
						next;
					}
					
					println "13.4.6.2" if $debug;
					$expandedValue	= $self->_5_1_2_expansion($activeCtx, $activeProp, $value, frameExpansion => $frameExpansion, ordered => $ordered);
					unless (ref($expandedValue) eq 'ARRAY') {
						$expandedValue	= [$expandedValue];
					}
					
					foreach my $v (@$expandedValue) {
						unless ($self->_is_node_object($v)) {
							println "13.4.6.3" if $debug;
							die 'invalid @included value';
						}
					}
					
					if (exists $result->{'@include'}) {
						println "13.4.6.4" if $debug;
						unshift(@$expandedValue, $result->{'@include'});
					}
					println "13.4.6 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
				} elsif ($expandedProperty eq '@value') {
					println "13.4.7 " . Data::Dumper->Dump([$input_type], ['*input_type']) if $debug;
					if ($input_type eq '@json') {
						println "13.4.7.1" if $debug;
						$expandedValue	= $value; # 13.4.7.1
						if ($self->processing_mode eq 'json-ld-1.0') {
							die 'invalid value object value';
						}
					} elsif (not (not(ref($value)) or not defined($value))) { # "if value is not a scalar or null, an invalid value object value error has been detected"
						println "13.4.7.2 " .  Data::Dumper->Dump([$value], ['*value']) if $debug; # NOTE: the language here is ambiguous: "if value is not a scalar or null"
						die 'invalid value object value';
					} else {
						println "13.4.7.3" if $debug;
						$expandedValue	= $value;
					}
					
					unless (defined($expandedValue)) {
						println "13.4.7.4" if $debug;
						$result->{'@value'}	= undef;
						next;
					}
					println "13.4.7 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
				}

				# NOTE: again with the "Otherwise" that seems to apply to only half the conjunction
				if ($expandedProperty eq '@language') {
					println "13.4.8" if $debug;
					if (ref($value)) {
						println "13.4.8.1" if $debug;
						if ($frameExpansion) {
							println "13.4.8.1 TODO: frameExpansion support"; # if $debug;
						}
						die 'invalid language-tagged string';
					}
					println "13.4.8.2" if $debug;
					$expandedValue	= $value; # 13.4.8.2
					# TODO: validate language tag against BCP47
					println "13.4.8 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
				}

				if ($expandedProperty eq '@direction') {
					println "13.4.9" if $debug;
					if ($self->processing_mode eq 'json-ld-1.0') {
						println "13.4.9.1" if $debug;
						next;
					}

					if ($value ne 'ltr' and $value ne 'rtl') {
						println "13.4.9.2" if $debug;
						die 'invalid base direction';
					}

					println "13.4.9.3" if $debug;
					$expandedValue	= $value;

					if ($frameExpansion) {
						println "13.4.9.4 TODO: frameExpansion support"; # if $debug;
					}
					println "13.4.9 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
				}

				if ($expandedProperty eq '@index') {
					println "13.4.10" if $debug;
					if (ref($value)) {
						println "13.4.10.1" if $debug;
						die 'invalid @index value';
					}
					
					println "13.4.10.2" if $debug;
					$expandedValue	= $value;
					println "13.4.10 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
				}

				if ($expandedProperty eq '@list') {
					println "13.4.11" if $debug;
					if (not defined($activeProp) or $activeProp eq '@graph') {
						println "13.4.11.1" if $debug;
						next;
					}

					println "13.4.11.2" if $debug;
					$expandedValue	= $self->_5_1_2_expansion($activeCtx, $activeProp, $value, frameExpansion => $frameExpansion, ordered => $ordered);
					println "13.4.11 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
				}

				if ($expandedProperty eq '@set') {
					println "13.4.12" if $debug;
					$expandedValue	= $self->_5_1_2_expansion($activeCtx, $activeProp, $value, frameExpansion => $frameExpansion, ordered => $ordered);
					println "13.4.12 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
				}

				# NOTE: the language here is really confusing. the first conditional in 13.4.13 is the conjunction "expanded property is @reverse and value is not a map".
				#       however, by context it seems that really everything under 13.4.13 assumes expanded property is @reverse, and the first branch is dependent only on 'value is not a map'.
				if ($expandedProperty eq '@reverse') {
					println "13.4.13" if $debug;
					if (ref($value) ne 'HASH') {
						println "13.4.13.1" if $debug;
						die 'invalid @reverse value';
					}

					println "13.4.13.2" if $debug;
					$expandedValue	= $self->_5_1_2_expansion($activeCtx, '@reverse', $value, frameExpansion => $frameExpansion, ordered => $ordered); # 13.4.13.1
					println "13.4.13.2 " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
					
					foreach my $ev (@{ $expandedValue }) { # https://github.com/w3c/json-ld-api/issues/294
						my $expandedValue	= $ev;
						if (ref($expandedValue) eq 'HASH' and exists $expandedValue->{'@reverse'}) { # NOTE: spec text does not assert that expandedValue is a map
							println "13.4.13.3" if $debug;
							foreach my $property (keys %{ $expandedValue->{'@reverse'} }) {
								my $__indent	= indent();
								println "13.4.13.3 [$property]" if $debug;
								my $item	= $expandedValue->{'@reverse'}{$property};
								if (not exists $result->{$property}) {
									println "13.4.13.3.1" if $debug;
									$result->{$property}	= [];
								}
							
								println "13.4.13.3.2" if $debug;
								push(@{ $result->{$property} }, $item);
							}
						}
					
						if (ref($expandedValue) eq 'HASH') { # NOTE: spec text does not assert that expandedValue is a map
							my @keys	= grep { $_ ne '@reverse' } keys %$expandedValue;
							if (scalar(@keys)) {
								println "13.4.13.4" if $debug;
						
								if (not exists $result->{'@reverse'}) {
									println "13.4.13.4.1" if $debug;
									$result->{'@reverse'}	= {};
								}
						
								println "13.4.13.4.2" if $debug;
								my $reverse_map	= $result->{'@reverse'};
						
								println "13.4.13.4.3" if $debug;
								foreach my $property (grep { $_ ne '@reverse' } keys %{ $expandedValue }) {
									my $__indent	= indent();
									println "13.4.13.4.3 [$property]" if $debug;
									my $items	= $expandedValue->{$property};
							
									println "13.4.13.4.3.1" if $debug;
									foreach my $item (@$items) {
										my $__indent	= indent();
										if ($self->_is_value_object($item) or $self->_is_list_object($item)) {
											println "13.4.13.4.3.1.1" if $debug;
											die 'invalid reverse property value';
										}
								
										if (not exists $reverse_map->{$property}) {
											println "13.4.13.4.3.1.2" if $debug;
											$reverse_map->{$property}	= [];
										}
								
										println "13.4.13.4.3.1.3" if $debug;
										push(@{ $reverse_map->{$property} }, $item);
									}
								}
							}
						}
					}
					println "13.4.13.5 going to next element key" if $debug;
					next; # 13.4.13.5
				}

				if ($expandedProperty eq '@nest') {
					println "13.4.14 adding '$key' to nests" if $debug;
					$nests->{$key}	//= [];
					next;
				}

				if ($frameExpansion) {
					my %other_framings	= map { $_ => 1 } qw(@explicit @default @embed @explicit @omitDefault @requireAll);
					if ($other_framings{$expandedProperty}) {
						println "13.4.15" if $debug;
						$expandedValue	= $self->_5_1_2_expansion($activeCtx, $activeProp, $value, frameExpansion => $frameExpansion, ordered => $ordered); # 13.4.15
						println "13.4.15 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
					}
				}
				
				println(Data::Dumper->Dump([$expandedValue, $expandedProperty, $input_type], [qw'expandedValue expandedProperty input_type'])) if $debug;
				unless (not(defined($expandedValue)) and $expandedProperty eq '@value' and $input_type ne '@json') {
					println "13.4.16 setting " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
# 						println "$expandedProperty expanded value is " . Dumper($expandedValue) if $debug;
					$result->{$expandedProperty}	= $expandedValue; # https://github.com/w3c/json-ld-api/issues/270
					println "13.4.16 resulting in " . Data::Dumper->Dump([$result], ['*result']) if $debug;
				}

				println "13.4.17 going to next element key" if $debug;
				next; # 13.4.17
			}


			my $tdef	= $self->_ctx_term_defn($activeCtx, $key);

			println "13.5 initializing container mapping" if $debug;
			my $container_mapping	= $tdef->{'container_mapping'}; # 13.5
			println(Data::Dumper->Dump([$container_mapping, $value], ['*container_mapping', '*value'])) if $debug;

			if (exists($tdef->{'type_mapping'}) and $tdef->{'type_mapping'} eq '@json') {
				println "13.6" if $debug;
				$expandedValue	= { '@value' => $value, '@type' => '@json' }; # 13.6
				println "13.6 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
			} elsif ($self->_cm_contains($container_mapping, '@language') and ref($value) eq 'HASH') {
				println "13.7" if $debug;
				println "13.7.1" if $debug;
				$expandedValue	= [];
				
				println "13.7.2" if $debug;
				my $direction	= $activeCtx->{'@direction'};
				
				if (exists $tdef->{'direction_mapping'}) {
					println "13.7.3" if $debug;
					$direction	= $tdef->{'direction_mapping'};
				}
				
				println "13.7.4" if $debug;
				for my $language (sort keys %$value) {
					my $__indent	= indent();
					my $language_value	= $value->{$language};
					println "13.7.4 [$language]" if $debug;
					
					if (ref($language_value) ne 'ARRAY') {
						println "13.7.4.1" if $debug;
						$language_value	= [$language_value];
					}
					
					println "13.7.4.2" if $debug;
					foreach my $item (@$language_value) {
						my $__indent	= indent();
						unless (defined($item)) {
							println "13.7.4.2.1" if $debug;
							next;
						}
						
						if (ref($item)) {
							println "13.7.4.2.2" if $debug;
							die 'invalid language map value';
						}
						
						println "13.7.4.2.3" if $debug;
						my $v	= {'@value' => $item, '@language' => $language};
						my $well_formed	= 1; # TODO: check BCP47 well-formedness of $item
						if ($item ne '@none' and not($well_formed)) {
							warn "Language tag is not well-formed: $item";
						}
						# TODO: normalize language tag
						
						my $expandedLanguage = $self->_5_2_2_iri_expansion($activeCtx, $language);
						if ($language eq '@none' or $expandedLanguage eq '@none') {
							println "13.7.4.2.4" if $debug;
							delete $v->{'@language'};
						}
						
						if (defined($direction)) {
							println "13.7.4.2.5" if $debug;
							$v->{'@direction'}	= $direction;
						}
						
						println "13.7.4.2.6" if $debug;
						push(@$expandedValue, $v);
					}
				}
				println "13.7 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
# 				} elsif ((exists $container_mapping->{'@index'} or exists $container_mapping->{'@type'} or exists $container_mapping->{'@id'}) and ref($value) eq 'HASH') {
			} elsif ($self->_cm_contains_any($container_mapping, '@index', '@type', '@id') and ref($value) eq 'HASH') {
				println "13.8" if $debug;
				println "13.8.1" if $debug;
				$expandedValue	= [];
				
				println "13.8.2" if $debug;
				my $index_key	= $tdef->{'index_mapping'} // '@index';
				
				println "13.8.3" if $debug;
				foreach my $index (sort keys %$value) {
					my $__indent	= indent();
					my $index_value	= $value->{$index};
					println '-----------------------------------------------------------------' if $debug;
					println "13.8.3 [$index]" if $debug;
					my $map_context;
					if ($self->_cm_contains_any($container_mapping, '@id', '@type')) {
						println "13.8.3.1" if $debug;
						$map_context	= $activeCtx->{'previous_context'} // $activeCtx;
					} else {
						$map_context	= $activeCtx;
					}
					
					my $index_tdef	= $self->_ctx_term_defn($map_context, $index);
					if ($self->_cm_contains_any($container_mapping, '@type') and exists $index_tdef->{'@context'}) {
						println "13.8.3.2" if $debug;
						$map_context	= $self->_4_1_2_ctx_processing($map_context, $index_tdef->{'@context'});
					} else {
						println "13.8.3.3" if $debug;
						$map_context	= $activeCtx;
					}
					
					println "13.8.3.4" if $debug;
					my $expanded_index	= $self->_5_2_2_iri_expansion($activeCtx, $index, vocab => 1);

					if (ref($index_value) ne 'ARRAY') {
						println "13.8.3.5" if $debug;
						$index_value	= [$index_value];
					}
					
					println "13.8.3.6" if $debug;
					$index_value	= $self->_expand($map_context, $key, $index_value, frameExpansion => $frameExpansion, ordered => $ordered);
					println(Data::Dumper->Dump([$index_value], ['*index_value'])) if $debug;
					
					println "13.8.3.7" if $debug;
					foreach my $item (@$index_value) {
						my $__indent	= indent();
						println '-----------------------------------------------------------------' if $debug;
						println "13.8.3.7 [$item]" if $debug;
						if ($self->_cm_contains($container_mapping, '@graph')) {
							println(Data::Dumper->Dump([$container_mapping], ['*container_mapping'])) if $debug;
							println "13.8.3.7.1" if $debug;
							$item	= {'@graph' => (ref($item) eq 'ARRAY') ? $item : [$item]};
							println(Data::Dumper->Dump([$item], ['*item'])) if $debug;
						}

						if ($self->_cm_contains($container_mapping, '@index') and $index_key ne '@index' and $expanded_index ne '@none') {
							println "13.8.3.7.2 " . Data::Dumper->Dump([$index_key], ['index_key']) if $debug;
							println "13.8.3.7.2.1" if $debug;
							my $re_expanded_index	= $self->_5_3_2_value_expand($activeCtx, $index_key, $index);
							println "13.8.3.7.2.2" if $debug;
							my $expanded_index_key	= $self->_5_2_2_iri_expansion($activeCtx, $index_key, vocab => 1);
							println "13.8.3.7.2.3" if $debug;
							my $index_property_values	= [$re_expanded_index];
							if (exists $item->{$expanded_index_key}) {
								my $v	= $item->{$expanded_index_key};
								if (ref($v) eq 'ARRAY') {
									push(@{$index_property_values}, @$v);
								} else {
									push(@{$index_property_values}, $v);
								}
							}
							println "13.8.3.7.2.4" if $debug;
							$item->{$expanded_index_key}	= $index_property_values;

							if ($self->_is_value_object($item)) {
								my @keys	= sort keys %$item;
								if (scalar(@keys) != 2) {
									die 'invalid value object';
								}
							}
						} elsif ($self->_cm_contains($container_mapping, '@index') and not exists $item->{'@index'} and $expanded_index ne '@none') {
							println "13.8.3.7.3" if $debug;
							$item->{'@index'}	= $index;
							println(Data::Dumper->Dump([$item], ['*item'])) if $debug;
						} elsif ($self->_cm_contains($container_mapping, '@id') and not exists $item->{'@id'} and $expanded_index ne '@none') {
							println "13.8.3.7.4" if $debug;
							$expanded_index	= $self->_5_2_2_iri_expansion($activeCtx, $index, documentRelative => 1);
							$item->{'@id'}	= $expanded_index;
						} elsif ($self->_cm_contains($container_mapping, '@type') and $expanded_index ne '@none') {
							println "13.8.3.7.5" if $debug;
							my $types	= [$expanded_index];
							if (exists $item->{'@type'}) {
								my $v	= $item->{'@type'};
								if (ref($v) eq 'ARRAY') {
									push(@$types, @{$item->{'@type'}});
								} else {
									push(@$types, $v);
								}
							}
							$item->{'@type'}	= $types;
							println "13.8.3.7.5 " . Data::Dumper->Dump([$types], ['types']) if $debug;
						}
						
						println "13.8.3.7.6" if $debug;
						push(@$expandedValue, $item);
					}
				}
				println "13.8 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
			} else {
				println "13.9" if $debug;
				$expandedValue	= $self->_5_1_2_expansion($activeCtx, $key, $value, frameExpansion => $frameExpansion, ordered => $ordered); # 13.9
				println "13.9 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
			}
		
# 				warn Dumper($expandedValue);
			if (not(defined($expandedValue))) {
				println "13.10 going to next element key" if $debug;
				next; # 13.10
			}
		
			if ($self->_cm_contains($container_mapping, '@list') and not $self->_is_list_object($expandedValue)) {
				# 13.11
				println "13.11" if $debug;
				my @values	= (ref($expandedValue) eq 'ARRAY') ? @$expandedValue : ($expandedValue);
				$expandedValue	= { '@list' => \@values };
				println "13.11 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
			}

# 				if (exists $container_mapping->{'@graph'}) {
			if ($self->_cm_contains($container_mapping, '@graph')) {
				# 13.12
				println "13.12" if $debug;
				if (ref($expandedValue) ne 'ARRAY') {
					$expandedValue	= [$expandedValue];
				}
				my @values;
				foreach my $ev (@$expandedValue) {
					println "is a graph object? " . Data::Dumper->Dump([$ev], ['*ev']) if $debug;
					if (not $self->_is_graph_object($ev)) {
						println "no" if $debug;
						# 13.12.1
						println "13.12.1" if $debug;
						my $av	= (ref($ev) eq 'ARRAY') ? $ev : [$ev];
						push(@values, {'@graph' => $av});
					} else {
						println "yes" if $debug;
						push(@values, $ev);
					}
				}
				$expandedValue	= \@values;
				println "13.12 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
			}
		
			if ($tdef->{'reverse'}) {
				# 13.13
				println "13.13" if $debug;
				unless (exists $result->{'@reverse'}) {
					println "13.13.1" if $debug;
					$result->{'@reverse'}	= {};
				}
				
				println "13.13.2" if $debug;
				my $reverse_map	= $result->{'@reverse'};
				
				if (ref($expandedValue) ne 'ARRAY') {
					println "13.13.3" if $debug;
					$expandedValue	= [$expandedValue];
				}
				
				foreach my $item (@$expandedValue) {
					println "13.13.4" if $debug;
					if ($self->_is_value_object($item) or $self->_is_list_object($item)) {
						println "13.13.4.1" if $debug;
						die 'invalid reverse property value';
					}
					
					unless (exists $reverse_map->{$expandedProperty}) {
						println "13.13.4.2" if $debug;
						$reverse_map->{$expandedProperty}	= [];
					}
					
					println "13.13.4.3" if $debug;
					push(@{ $reverse_map->{$expandedProperty} }, $item);
				}
				println "13.13 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
			} else {
				# 13.14
				println "13.14" if $debug;
				unless (exists $result->{$expandedProperty}) {
					println "13.14.1" if $debug;
					$result->{$expandedProperty}	= []; # 13.14.1
				}

				println "13.14.2" if $debug;
				if (ref($expandedValue) eq 'ARRAY') {
					push(@{$result->{$expandedProperty}}, @$expandedValue); # 13.14.2
				} elsif (ref($expandedValue)) {
					# NOTE: I'm assuming that this is the intention of 13.14.2,
					# but it isn't actually spelled out in the spec text.
					println "setting result[$expandedProperty]" if $debug;
					push(@{$result->{$expandedProperty}}, $expandedValue); # 13.14.2
				}
				println "13.14 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
			}
		}
		$self->_5_1_2_expansion_step_14($activeCtx, $type_scoped_ctx, $result, $activeProp, $input_type, $nests, $ordered, $frameExpansion, $element);
	}

	sub _5_1_2_expansion_step_14 {
		my $self			= shift;
		my $activeCtx		= shift;
		my $type_scoped_ctx	= shift;
		my $result			= shift;
		my $activeProp		= shift;
		my $input_type		= shift;
		my $nests			= shift;
		my $ordered			= shift;
		my $frameExpansion	= shift;
		my $element			= shift;
		
		# https://github.com/w3c/json-ld-api/issues/262
		println "14" if $debug;
		my @keys			= sort keys %$nests; # https://github.com/w3c/json-ld-api/issues/295
		foreach my $nesting_key (@keys) {
			delete $nests->{$nesting_key};
			# 14
			my $__indent	= indent();
			println "14 [$nesting_key]" if $debug;
			println "14.1" if $debug;
	# 		next unless (exists $element->{$nesting_key});
			my $nested_values	= $element->{$nesting_key}; # 14.1
			if (not defined $nested_values) {
				$nested_values	= [];
			}
			if (not(ref($nested_values)) or ref($nested_values) ne 'ARRAY') {
				$nested_values	= [$nested_values];
			}

			println "14.2" if $debug;
			println(Data::Dumper->Dump([$nesting_key, $element, $nested_values], [qw(nesting_key element nested_values)])) if $debug;
			foreach my $nested_value (@$nested_values) {
				my $__indent	= indent();
				println '-----------------------------------------------------------------' if $debug;
				println "14.2 loop iteration" if $debug;
				if (ref($nested_value) ne 'HASH') {
					println "14.2.1 " . Data::Dumper->Dump([$nested_value], ['*invalid_nest_value']) if $debug;
					die 'invalid @nest value'; # 14.2.1
				}
			
				println "14.2.2 ENTER    =================> call to _5_1_2_expansion_step_13" if $debug;
				my $__indent_2	= indent();
				$self->_5_1_2_expansion_step_13($activeCtx, $type_scoped_ctx, $result, $activeProp, $input_type, $nests, $ordered, $frameExpansion, $nested_value); # 14.2.2

			}
		}
		println "after 14 resulting in " . Data::Dumper->Dump([$result], ['*result']) if $debug;
	}

	sub _5_2_2_iri_expansion {
		my $self		= shift;
		my $activeCtx	= shift;
		my $value		= shift;
		println "ENTER    =================> _5_2_2_iri_expansion($value)" if $debug;
		my $__indent	= indent();
		my %args		= @_;
		my %acceptable	= map { $_ => 1 } qw(documentRelative vocab localCtx defined);
		foreach my $k (keys %args) {
			die "Not a recognized IRI expansion algorithm argument: $k" unless exists $acceptable{$k};
		}
		my $vocab				= $args{vocab} // 0;
		my $documentRelative	= $args{documentRelative} // 0;
		my $localCtx			= $args{localCtx} // {};
		my $defined				= $args{'defined'} // {};
		local($Data::Dumper::Indent)	= 0;
		println(Data::Dumper->Dump([$activeCtx], ['*activeCtx'])) if $debug;
		println(Data::Dumper->Dump([$localCtx], ['*localCtx'])) if $debug;
		println(Data::Dumper->Dump([$defined], ['*defined'])) if $debug;
		
		# 5.2.2 algorithm
		
		unless (defined($value) and not exists $keywords{$value}) {
			println "1 returning from _5_2_2_iri_expansion: undefined/keyword value" if $debug;
			return $value;
		}
		
		if ($value =~ /^@[A-Za-z]+$/) {
			println "2" if $debug;
			warn "IRI expansion attempted on a term that looks like a keyword: $value\n"; # 2
			return;
		}
		
		if (defined($localCtx) and my $v = $localCtx->{$value}) {
			unless ($defined->{$v}) {
				println "3" if $debug;
				$self->_4_2_2_create_term_definition($activeCtx, $localCtx, $value, $defined); # 3
			}
		}

		if (my $tdef = $self->_ctx_term_defn($activeCtx, $value)) {
			my $i	= $tdef->{'iri_mapping'};
			if ($keywords{$i}) {
				println "4 returning from _5_2_2_iri_expansion with a keyword: $i" if $debug;
				return $i; # 4
			}
		}
		
		if ($vocab and my $tdef = $self->_ctx_term_defn($activeCtx, $value)) {
			my $i	= $tdef->{'iri_mapping'};
			println "5 returning from _5_2_2_iri_expansion with iri mapping from active context: $i" if $debug;
			return $i; # 5
		}
		
		if ($value =~ /.:/) {
			 # 6
			println "6" if $debug;
			println "6.1" if $debug;
			my ($prefix, $suffix)	= split(/:/, $value, 2); # 6.1
			
			if ($prefix eq '_' or $suffix =~ m{^//}) {
				println "6.2 returning from _5_2_2_iri_expansion: already an absolute IRI or blank node identifier: $value" if $debug;
				return $value; # 6.2
			}
			
			if ($localCtx and exists $localCtx->{$prefix} and not($defined->{$prefix})) {
				println "6.3" if $debug;
				$self->_4_2_2_create_term_definition($activeCtx, $localCtx, $prefix, $defined);
			}
			
			my $tdef	= $self->_ctx_term_defn($activeCtx, $prefix);
			if ($tdef and $tdef->{'iri_mapping'} and $tdef->{'prefix'}) {
				my $i	= $tdef->{'iri_mapping'} . $suffix;
				println "6.4 returning from _5_2_2_iri_expansion with concatenated iri mapping and suffix: $i" if $debug;
				return $i;
			}
			
			if ($self->_is_abs_iri($value)) {
				println "6.5 returning from _5_2_2_iri_expansion with absolute IRI: $value" if $debug;
				return $value;
			}
		}
		
		if ($vocab and exists $activeCtx->{'@vocab'}) {
			my $i	= $activeCtx->{'@vocab'} . $value;
			println "7 returning from _5_2_2_iri_expansion with concatenated vocabulary mapping and value: $i" if $debug;
			return $i;
		} elsif ($documentRelative) {
			# 8
			println "8" if $debug;
			my $base = $activeCtx->{'@base'} // $self->base_iri;
			my $i = IRI->new(value => $value, base => $base);
			$value	= $i->abs;
		}

		println "9 returning from _5_2_2_iri_expansion with final value: $value" if $debug;
		return $value; # 9
	}
	
	sub _5_3_2_value_expand {
		my $self		= shift;
		my $activeCtx	= shift;
		my $activeProp	= shift;
		my $value		= shift;
		my $_vs			= Data::Dumper->new([$value], ['value'])->Terse(1)->Dump([$value], ['value']);
		println "ENTER    =================> _5_3_2_value_expand($_vs)" if $debug;
		my $__indent	= indent();
		
		my $tdef	= $self->_ctx_term_defn($activeCtx, $activeProp);

		if (exists $tdef->{'type_mapping'}) {
			if ($tdef->{'type_mapping'} eq '@id' and _is_string($value)) {
				my $iri	= $self->_5_2_2_iri_expansion($activeCtx, $value, documentRelative => 1);
				println "1 returning from _5_3_2_value_expand with new map containing \@id: $iri" if $debug;
				return { '@id' => $iri }; # 1
			}

			if ($tdef->{'type_mapping'} eq '@vocab' and _is_string($value)) {
				my $iri	= $self->_5_2_2_iri_expansion($activeCtx, $value, vocab => 1, documentRelative => 1);
				println "1 returning from _5_3_2_value_expand with new map containing vocab \@id: $iri" if $debug;
				return { '@id' => $iri }; # 2
			}
		}
		
		println "3" if $debug;
		my $result	= { '@value' => $value }; # 3
		
		my $tm	= $tdef->{'type_mapping'};
		if (exists($tdef->{'type_mapping'}) and $tm ne '@id' and $tm ne '@vocab' and $tm ne '@none') {
			println "4" if $debug;
			$result->{'@type'}	= $tm; # 4
		} elsif (_is_string($value)) { # not(ref($value))) {
			println "5" if $debug;
			println "5.1" if $debug;
			my $language	= (exists $tdef->{'language_mapping'}) ? $tdef->{'language_mapping'} : $activeCtx->{'@language'}; # 5.1

			println "5.2" if $debug;
			my $direction	= (exists $tdef->{'direction_mapping'}) ? $tdef->{'direction_mapping'} : $activeCtx->{'@direction'}; # 5.2

			if (defined($language)) {
				println "5.3" if $debug;
				$result->{'@language'}	= $language; # 5.3
			}
			
			if (defined($direction)) {
				println "5.4" if $debug;
				$result->{'@direction'}	= $direction; # 5.4
			}
		}
		
		println "6 returning from _5_3_2_value_expand with final result" if $debug;
		return $result; # 6
	}

=item C<< to_rdf( $data ) >>

Returns the dataset generated by turning the JSON-LD expansion of C<< $data >> into RDF.

Note: this method must be called on a C<< JSONLD >> subclass which implements the
RDF-related methods:

=over 4

=item * C<< default_graph() >>
	
=item * C<< new_dataset() >>
	
=item * C<< new_triple($s, $p, $o) >>
	
=item * C<< new_quad($s, $p, $o, $g) >>
	
=item * C<< new_iri($value) >>

=item * C<< new_graphname($value) >>
	
=item * C<< new_blank( [$id] ) >>
	
=item * C<< new_lang_literal($value, $lang) >>
	
=item * C<< new_dt_literal($value, $datatype) >>

=item * C<< add_quad($quad, $dataset) >>

=back

=cut

	sub to_rdf {
		my $self	= shift;
		my $obj		= shift;
		my $expandedInput	= $self->expand($obj);
		println "to rdf " . Data::Dumper->Dump([$expandedInput], ['expandedInput']) if $debug;
		my $dataset	= $self->new_dataset;
		my $map		= {};
		$self->identifier_map({});
		$self->next_identifier_id(0);
		$self->_7_2_2_nodemap_generation($expandedInput, $map);
		println(Data::Dumper->Dump([$map], ['node_map'])) if $debug;

		$self->_8_1_2_to_rdf($map, $dataset);
		return $dataset;
	}
	
	sub _is_well_formed_language {
		my $self	= shift;
		my $value	= shift;
		my $ok	= ($value =~ m/^[a-zA-Z]{1,8}(-[a-zA-Z0-9]{1,8})*$/);
		if (not $ok) {
			println "not a well-formed language: $value\n" if $debug;
		}
		return $ok;
	}
	
	sub _is_well_formed_iri {
		my $self	= shift;
		my $value	= shift;
		my $ok	= ($self->_is_abs_iri($value));
		if (not $ok) {
			println "not a well-formed IRI: $value\n" if $debug;
		}
		return $ok;
	}
	
	sub _is_well_formed_graphname {
		my $self	= shift;
		my $value	= shift;
		my $ok	= ($self->_is_abs_iri($value) or ($value eq '@default') or ($value =~ /^_:(\w+)$/));
		if (not $ok) {
			println "not a well-formed graph name: $value\n" if $debug;
		}
		return $ok;
	}
	
	sub _is_well_formed {
		my $self	= shift;
		my $value	= shift;
		println "TODO: _is_well_formed: $value" if $debug;
		return 1;
	}

	sub _7_1_2_flattening {
		my $self			= shift;
		my $element			= shift;
		my $context			= shift;
		my $ordered			= shift // 0;
		die;
	}	

	sub _7_2_2_nodemap_generation {
		println "ENTER    =================> _7_2_2_nodemap_generation" if $debug;
		my $__indent	= indent();
		my $self			= shift;
		my $element			= shift;
		my $map				= shift;
		my $activeGraph		= shift // '@default';
		my $activeSubject	= shift;
		my $activeProp		= shift;
		my $list			= shift;
		
		println "1" if $debug;
		if (ref($element) eq 'ARRAY') {
			foreach my $item (@$element) {
				$self->_7_2_2_nodemap_generation($item, $map, $activeGraph, $activeSubject, $activeProp, $list);
			}
			return;
		}
		
		println "2" if $debug;
		my $graph	= ($map->{$activeGraph} ||= {});
		my $node;
		my $subjectNode;
		if (not defined($activeSubject)) {
			$node	= undef;
		} else {
			$subjectNode	= $graph->{$activeSubject};
		}
		
		unless (ref($element) eq 'HASH') {
			Carp::cluck 'element is not a HASH';
		}
		
		if (exists $element->{'@type'}) {
			println "3" if $debug;
			# https://github.com/w3c/json-ld-api/issues/276
			if (ref($element) and ref($element) ne 'HASH') {
				Carp::cluck 'element is not a HASH';
			}
			if (ref($element->{'@type'})) {
				foreach my $i (0 .. $#{ $element->{'@type'} }) {
					my $item	= $element->{'@type'}[$i];
					if ($item =~ /^_:/) {
						println "3.1" if $debug;
						$element->{'@type'}[$i]	= $self->_7_4_2_generate_blank_node_ident($item);
					}
				}
			} else {
				if ($element->{'@type'} =~ /^_:/) {
					$element->{'@type'}	= $self->_7_4_2_generate_blank_node_ident($element->{'@type'});
				}
			}
		}
		
		my $j	= JSON->new()->canonical(1);
		if (exists $element->{'@value'}) {
			println "4" if $debug;
			if (not defined($list)) {
				println "4.1" if $debug;
				no warnings 'uninitialized';
				if (not exists $subjectNode->{$activeProp}) {
					println "4.1.1" if $debug;
					$subjectNode->{$activeProp}	= [$element];
				} else {
					println "4.1.2" if $debug;
					my $je	= $j->encode($element);
					my $exists	= any { $j->encode($_) eq $je } @{ $subjectNode->{$activeProp} };
					unless ($exists) {
						push(@{ $subjectNode->{$activeProp} }, $element);
					}
				}
			}
		} elsif (exists $element->{'@list'}) {
			println "5" if $debug;
			println "5.1" if $debug;
			my $result	= {'@list' => []};
			
			println "5.2" if $debug;
			$self->_7_2_2_nodemap_generation($element->{'@list'}, $map, $activeGraph, $activeSubject, $activeProp, $list);
			
			if (not defined($list)) {
				println "5.3" if $debug;
				push(@{ $subjectNode->{$activeProp} }, $result);
			} else {
				println "5.4" if $debug;
				push(@{ $list->{'@list'} }, $result);
			}
		} else {
			println "6" if $debug;
			my $id;
			if (exists $element->{'@id'}) {
				println "6.1" if $debug;
				$id	= delete $element->{'@id'};
				if ($id =~ /^_:/) {
					$id	= $self->_7_4_2_generate_blank_node_ident($id);
				}
			} else {
				println "6.2" if $debug;
				$id	= $self->_7_4_2_generate_blank_node_ident();
			}
			
			unless (exists $graph->{$id}) {
				println "6.3" if $debug;
				$graph->{$id}	= { '@id' => $id };
			}
			
			println "6.4" if $debug;
			$node	= $graph->{$id};
			
			if (ref($activeSubject) eq 'HASH') {
				println "6.5" if $debug;
				if (not exists $node->{$activeProp}) {
					println "6.5.1" if $debug;
					$node->{$activeProp}	= [$activeSubject];
				} else {
					println "6.5.2" if $debug;
					my $je	= $j->encode($activeSubject);
					my $exists	= any { $j->encode($_) eq $je } @{ $node->{$activeProp} };
					unless ($exists) {
						push(@{ $node->{$activeProp} }, $activeSubject);
					}
				}
			} elsif (defined($activeProp)) {
				println "6.6" if $debug;
				println "6.6.1" if $debug;
				my $reference	= { '@id' => $id };
				
				if (not defined($list)) {
					println "6.6.2" if $debug;
					if (not exists $subjectNode->{$activeProp}) {
						println "6.6.2.1" if $debug;
						$subjectNode->{$activeProp}	= [$reference];
					} else {
						println "6.6.2.2" if $debug;
						my $je	= $j->encode($reference);
						my $exists	= any { $j->encode($_) eq $je } @{ $subjectNode->{$activeProp} };
						unless ($exists) {
							push(@{ $subjectNode->{$activeProp} }, $reference);
						}
					}
				}
			}
			
			if (exists $element->{'@type'}) {
				println "6.7" if $debug;
				my %exists	= map { $_ => 1 } @{ $element->{'@type'} };
				push(@{ $node->{'@type'} }, grep { not exists $exists{$_} }@{ $element->{'@type'} });
				delete $element->{'@type'};
			}
			
			if (exists $element->{'@index'}) {
				println "6.8" if $debug;
				println "6.8 TODO check if element has a pre-existing value" if $debug;
				$node->{'@index'}	= delete $element->{'@index'};
			}

			if (exists $element->{'@reverse'}) {
				println "6.9" if $debug;
				println "6.9.1" if $debug;
				my $referenced_node	= { '@id' => $id };
				
				println "6.9.2" if $debug;
				my $reverse_map	= $element->{'@reverse'};
				
				println "6.9.3" if $debug;
				foreach my $property (keys %$reverse_map) {
					println "6.9.3 [$property]" if $debug;
					my $values	= $reverse_map->{$property};
					
					println "6.9.3.1" if $debug;
					foreach my $value (@$values) {
						println "6.9.3.1.1" if $debug;
						$self->_7_2_2_nodemap_generation($value, $map, $activeGraph, $referenced_node, $property); # TODO: need to pass $list ?
					}
				}

				println "6.9.3.4" if $debug;
				delete $element->{'@reverse'};
			}
						
			if (exists $element->{'@graph'}) {
				println "6.10" if $debug;
				$self->_7_2_2_nodemap_generation($element->{'@graph'}, $map, $id);
				delete $element->{'@graph'};
			}
						
			if (exists $element->{'@included'}) {
				println "6.11" if $debug;
				$self->_7_2_2_nodemap_generation($element->{'@included'}, $map, $id);
				delete $element->{'@included'};
			}

			println "6.12" if $debug;
			foreach my $property (sort keys %$element) {
				println '----------------' if $debug;
				println "6.12 [$property]" if $debug;
				my $value	= $element->{$property};
				if ($property =~ /^_:/) {
					println "6.12.1" if $debug;
					$property	= $self->_7_4_2_generate_blank_node_ident($property);
				}
				unless (exists $node->{$property}) {
					println "6.12.2" if $debug;
					$node->{$property}	= [];
				}
				
				println "6.12.3" if $debug;
				$self->_7_2_2_nodemap_generation($value, $map, $activeGraph, $id, $property);
			}
		}
	}

	sub _7_4_2_generate_blank_node_ident {
		println "ENTER    =================> _7_4_2_generate_blank_node_ident" if $debug;
		my $__indent	= indent();
		my $self	= shift;
		my $ident	= shift;
		if (defined($ident) and exists $self->identifier_map->{$ident}) {
			println "1" if $debug;
			return $self->identifier_map->{$ident};
		}
		
		println "2" if $debug;
		my $nid	= $self->next_identifier_id;
		$self->next_identifier_id($nid + 1);
		my $bid	= "_:b$nid";

		if (defined($ident)) {
			println "3" if $debug;
			$self->identifier_map->{$ident}	= $bid;
		}
		
		println "4" if $debug;
		return $bid;
	}

	sub _8_1_2_to_rdf {
		println "ENTER    =================> _8_1_2_to_rdf" if $debug;
		my $__indent	= indent();
		my $self	= shift;
		my $map		= shift;
		my $dataset	= shift;
		my %args	= @_;
		my $produce_genrdf	= $args{'produceGeneralizedRdf'} || 0;
		my $rdfDirection	= $args{'rdfDirection'};
		
		println "1" if $debug;
		for my $graphName (keys %$map) {
			my $__indent	= indent();
			println '----------------------' if $debug;
			println "1 [$graphName]" if $debug;
			my $graph	= $map->{$graphName};

			unless ($self->_is_well_formed_graphname($graphName)) {
				println "1.1" if $debug;
				next;
			}
			
			my $graph_iri;
			println "1.2" if $debug;
			if ($graphName eq '@default') {
				$graph_iri	= $self->default_graph();
			} else {
				$graph_iri	= $self->new_graphname($graphName);
			}
			
			println "1.3" if $debug;
			foreach my $subject (sort keys %$graph) {
				my $__indent	= indent();
				println '----------------------' if $debug;
				println "1.3 [$subject]" if $debug;
				my $node	= $graph->{$subject};

				println "1.3.2" if $debug;
				foreach my $property (sort keys %$node) {
					println "1.3.2 [$property]" if $debug;
					my $values	= $node->{$property};
					println(Dumper($property, $node)) if $debug;
					if ($property eq '@type') {
						println "1.3.2.1" if $debug;
						foreach my $type (@$values) {
							if ($self->_is_well_formed_iri($type)) {
								my $q	= $self->new_quad(
									$subject,
									$self->new_iri('http://www.w3.org/1999/02/22-rdf-syntax-ns#type'),
									$type,
									$graph_iri
								);
								$self->add_quad($q, $dataset);
							}
						}
					} elsif (exists $keywords{$property}) {
						println "1.3.2.2" if $debug;
						next;
					} elsif ($property =~ /^_:(.*)$/ and not $produce_genrdf) {
						println "1.3.2.3" if $debug;
						next;
					} elsif (not $self->_is_well_formed_iri($property)) {
						println "1.3.2.4" if $debug;
						next;
					} else {
						println "1.3.2.5" if $debug;
						foreach my $item (@$values) {
							println "1.3.2.5.1" if $debug;
							println "1.3.2.5.2" if $debug;
							my $list_triples	= [];
							my $s	= $self->_8_2_2_object_to_rdf({'@id' => $subject}, $list_triples);
							my $o	= $self->_8_2_2_object_to_rdf($item, $list_triples);
							if ($o) {
								println "1.3.2.5.3" if $debug;
								my $q	= $self->new_quad(
									$s,
									$self->new_iri($property),
									$o,
									$graph_iri
								);
								$self->add_quad($q, $dataset);
							}
							println "1.3.2.5.4" if $debug;
							foreach my $q (@$list_triples) {
								$self->add_quad($q, $dataset);
							}
						}
					}
				}
			}
		}
	}

	sub _8_2_2_object_to_rdf {
		println "ENTER    =================> _8_2_2_object_to_rdf" if $debug;
		my $__indent	= indent();
		my $self			= shift;
		my $item			= shift;
		my $list_triples	= shift;
		if ($self->_is_node_object($item) and not $self->_is_well_formed_iri($item->{'@id'})) {
			println "1" if $debug;
			return;
		}

		if ($self->_is_node_object($item)) {
			my $value	= $item->{'@id'};
			println "2 $value" if $debug;
			if ($value =~ /^_:(.*)$/) {
				return $self->new_blank($1);
			} else {
				return $self->new_iri($value);
			}
		}
		
		if ($self->_is_list_object($item)) {
			println "3" if $debug;
			return $self->_8_3_2_list_conversion($item->{'@list'}, $list_triples);
		}
		
		println "4" if $debug;
		my $value	= $item->{'@value'};
		
		println "5" if $debug;
		my $datatype	= $item->{'@type'};

		if (defined($datatype) and not $self->_is_well_formed_iri($datatype)) { # https://github.com/w3c/json-ld-api/issues/282
			println "6" if $debug;
			return;
		}
		
		if (exists $item->{'@language'} and not $self->_is_well_formed_language($item->{'@language'})) {
			println "7" if $debug;
			return;
		}
		
		if (defined($datatype) and $datatype eq '@json') {
			println "8" if $debug;
			$value		= encode_json($value);
			$datatype	= 'http://www.w3.org/1999/02/22-rdf-syntax-ns#JSON';
		}
		
		println "9 TODO bool? " . Data::Dumper->Dump([$value], ['value']) if $debug;
		println "10/11 TODO numeric? " . Data::Dumper->Dump([$value], ['value']) if $debug;
		
		if (not defined($datatype)) {
			println "12" if $debug;
			$datatype	= (exists $item->{'@language'}) ? 'http://www.w3.org/1999/02/22-rdf-syntax-ns#langString' : 'http://www.w3.org/2001/XMLSchema#string';
		}
		
		my $literal;
		if (exists $item->{'@direction'} and defined(my $dir = $self->rdf_direction)) {
			println "13" if $debug;
			if ($dir eq 'i18n-datatype') {
				println "13.1" if $debug;
				my $language	= $item->{'@language'} // ''; # https://github.com/w3c/json-ld-api/issues/277
				$datatype	= join('_', 'https://www.w3.org/ns/i18n#', $language, $item->{'@direction'});
				$literal	= $self->new_dt_literal($value, $datatype);
			} elsif ($dir eq 'compound-literal') {
				println "13.2" if $debug;
				println "13.2.1" if $debug;
				$literal	= $self->new_blank();
				println "13.2.2" if $debug;
				my $t	= $self->new_triple(
					$literal,
					$self->new_iri('http://www.w3.org/1999/02/22-rdf-syntax-ns#value'),
					$item->{'@value'} # TODO: should this be a term constructor call?
				);
				push(@$list_triples, $t);
				
				if (exists $item->{'@language'}) {
					println "13.2.3" if $debug;
					my $t	= $self->new_triple(
						$literal,
						$self->new_iri('http://www.w3.org/1999/02/22-rdf-syntax-ns#language'),
						$item->{'@language'} # TODO: should this be a term constructor call?
					);
					push(@$list_triples, $t);
				}
				
				println "13.2.4" if $debug;
				my $t2	= $self->new_triple(
					$literal,
					$self->new_iri('http://www.w3.org/1999/02/22-rdf-syntax-ns#direction'),
					$item->{'@direction'} # TODO: should this be a term constructor call?
				);
				push(@$list_triples, $t2);
			}
		} else {
			println "14" if $debug;
			$literal	= (exists $item->{'@language'}) ? $self->new_lang_literal($value, $item->{'@language'}) : $self->new_dt_literal($value, $datatype);
		}
		
		println "15" if $debug;
		return $literal;
	}

	sub _8_3_2_list_conversion {
		println "ENTER    =================> _8_3_2_list_conversion" if $debug;
		my $__indent	= indent();
		die 'TODO 8.3.2 list_conversion';
	}
	
	sub new_graphname {
		my $self	= shift;
		Carp::cluck 'RDF term constructors must be overloaded in a JSONLD subclass';
	}

	sub default_graph {
		my $self	= shift;
		Carp::cluck 'RDF default graph accessor must be overloaded in a JSONLD subclass';
	}
	
	sub new_dataset {
		my $self	= shift;
		Carp::cluck 'RDF dataset constructors must be overloaded in a JSONLD subclass';
	}
	
	sub new_triple {
		my $self	= shift;
		Carp::cluck 'RDF statement constructors must be overloaded in a JSONLD subclass';
	}
	
	sub new_quad {
		my $self	= shift;
		Carp::cluck 'RDF statement constructors must be overloaded in a JSONLD subclass';
	}
	
	sub new_iri {
		my $self	= shift;
		Carp::cluck 'RDF term constructors must be overloaded in a JSONLD subclass';
	}
	
	sub new_blank {
		my $self	= shift;
		Carp::cluck 'RDF term constructors must be overloaded in a JSONLD subclass';
	}
	
	sub new_lang_literal {
		my $self	= shift;
		Carp::cluck 'RDF term constructors must be overloaded in a JSONLD subclass';
	}
	
	sub new_dt_literal {
		my $self	= shift;
		Carp::cluck 'RDF term constructors must be overloaded in a JSONLD subclass';
	}
	
	sub add_quad {
		my $self	= shift;
		Carp::cluck 'RDF dataset methods must be overloaded in a JSONLD subclass';
	}
}



1;

__END__

=back

=head1 BUGS

Please report any bugs or feature requests to through the GitHub web interface
at L<https://github.com/kasei/perl-jsonld/issues>.

=head1 SEE ALSO

=over 4

=item L<AtteanX::Parser::JSONLD>

=item L<https://www.w3.org/TR/json-ld11/>

=item L<https://www.w3.org/TR/json-ld-api/>

=back

=head1 AUTHOR

Gregory Todd Williams  C<< <gwilliams@cpan.org> >>

=head1 COPYRIGHT

Copyright (c) 2019--2020 Gregory Todd Williams.
This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
