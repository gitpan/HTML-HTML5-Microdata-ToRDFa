package HTML::HTML5::Microdata::ToRDFa;

=head1 NAME

HTML::HTML5::Microdata::ToRDFa - rewrite HTML5+Microdata into XHTML+RDFa

=head1 SYNOPSIS

 use HTML::HTML5::Microdata::ToRDFa;
 my $rdfa = HTML::HTML5::Microdata::ToRDFa->new($html, $baseuri);
 print $rdfa->get_string;

=cut

use 5.008;
use strict;

use Digest::SHA1 qw(sha1_hex);
use HTML::HTML5::Microdata::Parser 0.02;
use URI::Escape;
use XML::LibXML qw(:all);

=head1 VERSION

0.02

=cut

our $VERSION = '0.02';

=head1 DESCRIPTION

This module may be used to convert HTML documents marked up with Microdata
into XHTML+RDFa (which is more widely implemented by consuming software).

If the input document uses a mixture of Microdata and RDFa, the semantics of the
output document may be incorrect.

=head2 Constructors

=over 4

=item C<< $rdfa = HTML::HTML5::Microdata::ToRDFa->new($html, $baseuri) >>

$html may be an HTML document (as a string) or an XML::LibXML::Document
object.

$baseuri is the base URI for resolving relative URI references. If $html is undefined,
then this module will fetch $baseuri to obtain the document to be converted.

=back

=cut

sub new
{
	my $class = shift;
	my $html  = shift;
	my $base  = shift;
	
	my $self  = bless { 'bnodes'=>0, 'dom'=>undef, 'parser'=>undef, 'prefix'=>{} }, $class;
	
	$self->{'parser'} = HTML::HTML5::Microdata::Parser->new($html, $base);
	$self->{'dom'}    = $self->{'parser'}->dom;
	
	while (<DATA>)
	{
		chomp;
		my ($prefix, $expand) = split /\t/;
		$self->{'prefix'}->{$expand} = $prefix;
	}
	
	return $self;
}

=head2 Public Methods

=over 4

=item C<< $rdfa->get_string >>

Get the document converted to RDFa as a string. This will be well-formed XML, but not
necessarily valid XHTML.

=cut

sub get_string
{
	my $self = shift;
	return q(<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML+RDFa 1.0//EN" "http://www.w3.org/MarkUp/DTD/xhtml-rdfa-1.dtd">)
		. "\r\n"
		. $self->get_dom->documentElement->toString
		. "\r\n";
}

=item C<< $rdfa->get_dom >>

Get the document converted to XHTML+RDFa as an L<XML::LibXML::Document>
object.

Note that each time C<get_string> and C<get_dom> are called, the 
conversion process is run from scratch. Repeatedly calling these 
methods is wasteful.

=cut

sub get_dom
{
	my $self  = shift;
	my $clone;
	
	# Is there a better way to clone an XML::LibXML::Document?
	{
		my $parser = XML::LibXML->new();
		$clone = $parser->parse_string( $self->{'dom'}->toString );
	}
	
	$self->_process_element($clone->documentElement, undef, $self->{'parser'}->uri);
	
	return $clone;
}

sub _process_element
{
	my $self    = shift;
	my $elem    = shift;
	my $subject = shift;
	my $rdfa_subject = shift;
	
	my ($new_subject, $new_rdfa_subject);
	
	if ($elem->hasAttribute('itemscope'))
	{
		if ($elem->hasAttribute('itemid'))
		{
			$new_subject = $elem->getAttribute('itemid');
		}
		else
		{
			$new_subject = $self->_bnode;
		}
	}

	unless (defined $subject || defined $new_subject)
	{
		foreach my $attr (qw(itemprop itemtype itemid itemref))
		{
			$elem->removeAttribute($attr)
				if $elem->hasAttribute($attr);
		}
	}

	# This is complicated and annoying, but it's good to handle @itemref.
	# This technique should work for the vast majority of cases.
	if ($elem->hasAttribute('itemref') and $elem->hasAttribute('itemscope'))
	{
		my @new_nodes;
		$self->{'parser'}->set_callbacks({'ontriple'=>sub {
			my $parser  = shift;
			my $node    = shift;
			my $triple  = shift;
			
			# if $node is an element outside of $elem
			if ((substr $node->nodePath, 0, length $elem->nodePath) ne $elem->nodePath)
			{
				my $new = $elem->addNewChild('http://www.w3.org/1999/xhtml', 'span');
				$new->setAttribute('class', 'microdata-to-rdfa--itemref');
				push @new_nodes, $new;
				
				if ($triple->subject->is_blank)
				{
					$new->setAttribute('about' => '_:'.$triple->subject->blank_identifier);
				}
				else
				{
					$new->setAttribute('about' => $triple->subject->uri);
				}
				if ($triple->object->is_literal)
				{
					$new->setAttribute('property' => $self->_super_split($new, $triple->predicate->uri));
					$new->setAttribute('content'  => $triple->object->literal_value);
					$new->setAttribute('datatype' => $self->_super_split($new, $triple->object->literal_datatype))
						if $triple->object->has_datatype;
					$new->setAttribute('xml:lang' => $triple->object->literal_value_language)
						if $triple->object->has_language;
				}
				else
				{
					$new->setAttribute('rel' => $self->_super_split($new, $triple->predicate->uri));
					if ($triple->object->is_blank)
					{
						$new->setAttribute('resource' => '_:'.$triple->object->blank_identifier);
					}
					else
					{
						$new->setAttribute('resource' => $triple->object->uri);
					}
				}
			}
			
			return 1;
			}});
		my $new_uri = $self->{'parser'}->consume_microdata_item( $self->_get_orig_node($elem) );
		
		# consume_microdata_item would have issued a new blank node identifier
		# for the item. Let's write over that.
		foreach my $node (@new_nodes)
		{
			$node->setAttribute('about' => $subject)
				if $node->getAttribute('about') eq $new_uri;
			$node->setAttribute('resource' => $subject)
				if $node->getAttribute('resource') eq $new_uri;
		}
		
		$elem->removeAttribute('itemref');
	}

	$elem->removeAttribute('itemscope')
		if $elem->hasAttribute('itemscope');

	# This copes with <a href="..."><span itemprop="...">...</span></a>
	# and related. The @href shouldn't set a new subject in Microdata.
	$new_rdfa_subject = $elem->getAttribute('href')
		if $elem->hasAttribute('href')
		&& !$elem->hasAttribute('itemprop');
	$new_rdfa_subject = $elem->getAttribute('src')
		if $elem->hasAttribute('src')
		&& !$elem->hasAttribute('itemprop');

	if (defined $new_subject && !$elem->hasAttribute('itemprop'))
	{
		$elem->setAttribute('about' => $new_subject);
		$elem->removeAttribute('itemid')
			if $elem->hasAttribute('itemid');
		
		if ($elem->hasAttribute('itemtype'))
		{
			my ($expand, $prefix, $suffix) = $self->_split($elem->getAttribute('itemtype'));
			$elem->setAttribute('typeof' => "$prefix:$suffix");
			$elem->setAttribute("xmlns:$prefix" => $expand);
			$elem->removeAttribute('itemtype');
		}
	}

	elsif (defined $new_subject && $elem->hasAttribute('itemprop'))
	{
		$elem->setAttribute('resource' => $new_subject);
		$elem->removeAttribute('itemid')
			if $elem->hasAttribute('itemid');
		
		$elem->setAttribute(
			'rel' => $self->_super_split($elem, $elem->getAttribute('itemprop'))
			);
		$elem->removeAttribute('itemprop');
		
		if ($elem->hasAttribute('itemtype'))
		{
			my $new = $elem->addNewChild('http://www.w3.org/1999/xhtml', 'span');
			$new->setAttribute('class', 'microdata-to-rdfa--rdftype');
			
			my ($expand, $prefix, $suffix) = $self->_split($elem->getAttribute('itemtype'));			
			$new->setAttribute('resource' => "[$prefix:$suffix]");
			$new->setAttribute("xmlns:$prefix" => $expand);

			($expand, $prefix, $suffix) = $self->_split('http://www.w3.org/1999/02/22-rdf-syntax-ns#type');
			$new->setAttribute('resource' => "[$prefix:$suffix]");
			$new->setAttribute("xmlns:$prefix" => $expand);
		}		
	}

	elsif ($elem->hasAttribute('itemprop'))
	{
		if ($elem->localname =~ /^(audio | embed | iframe | img | source | video)$/ix)
		{
			if ($elem->hasAttribute('src'))
			{
				$elem->setAttribute(
					'rel' => $self->_super_split($elem, $elem->getAttribute('itemprop'))
					);
				$elem->removeAttribute('itemprop');
				
				$elem->setAttribute('about' => $subject);
				$elem->setAttribute('resource' => $elem->getAttribute('src'));
			}
			else
			{
				$elem->setAttribute(
					'property' => $self->_super_split($elem, $elem->getAttribute('itemprop'))
					);
				$elem->removeAttribute('itemprop');
				
				$elem->setAttribute('about' => $subject);
				$elem->setAttribute('content' => '');
			}
		}
		elsif ($elem->localname =~ /^(a | area | link)$/ix)
		{
			if ($elem->hasAttribute('href'))
			{
				$elem->setAttribute(
					'rel' => $self->_super_split($elem, $elem->getAttribute('itemprop'))
					);
				$elem->removeAttribute('itemprop');
			}
			else
			{
				$elem->setAttribute(
					'property' => $self->_super_split($elem, $elem->getAttribute('itemprop'))
					);
				$elem->removeAttribute('itemprop');
				
				$elem->setAttribute('content' => '');
			}
		}
		elsif ($elem->localname =~ /^(object)$/ix)
		{
			if ($elem->hasAttribute('data'))
			{
				$elem->setAttribute(
					'rel' => $self->_super_split($elem, $elem->getAttribute('itemprop'))
					);
				$elem->removeAttribute('itemprop');
				$elem->setAttribute('resource' => $elem->getAttribute('data'));
			}
			else
			{
				$elem->setAttribute(
					'property' => $self->_super_split($elem, $elem->getAttribute('itemprop'))
					);
				$elem->removeAttribute('itemprop');
				$elem->setAttribute('content' => '');
			}
		}
		else
		{
			$elem->setAttribute(
				'property' => $self->_super_split($elem, $elem->getAttribute('itemprop'))
				);
			$elem->removeAttribute('itemprop');
			$elem->setAttribute('datatype' => '')
				if $elem->getChildrenByTagName('*');
		}
	}

	if ($subject ne $rdfa_subject
	and ($elem->hasAttribute('rel') || $elem->hasAttribute('property'))
	and !$elem->hasAttribute('about'))
	{
		$elem->setAttribute('about' => $subject);
	}
	
	foreach my $kid ($elem->getChildrenByTagName('*'))
	{
		$self->_process_element($kid, $new_subject||$subject, $new_rdfa_subject||$rdfa_subject);
	}
}

sub _split
{
	my $self = shift;
	my $uri  = shift;
	
	my ($expand, $suffix) = ($uri =~ m'^(.+?)([^/#]+)$');
	unless (length $expand and length $suffix)
	{
		$suffix = '';
		$expand = $uri;
	}
	
	unless (defined $self->{'prefix'}->{$expand})
	{
		$self->{'prefix'}->{$expand} = 'ns-'.(substr sha1_hex($expand), 0, 8);
	}
	
	return ($expand, $self->{'prefix'}->{$expand}, $suffix);
}

sub _super_split
{
	my $self = shift;
	my $elem = shift;
	my $str  = shift;
	
	my $type = $self->_get_node_type( $self->_get_orig_node($elem) );
	
	my @rv;
	my @props = split /\s+/, $str;
	
	foreach my $p (@props)
	{
		if ($p =~ /:/)
		{
			my ($expand, $prefix, $suffix) = $self->_split($p);
			$elem->setAttribute("xmlns:$prefix" => $expand);
			push @rv, "$prefix:$suffix";
		}
		
		elsif (defined $type and length $p)
		{
			my $_p = $type;
			$_p .= '#' unless $_p =~ /#/;
			$_p .= ':';
			$_p  = "http://www.w3.org/1999/xhtml/microdata#" . uri_escape($_p . uri_escape($p));
			my ($expand, $prefix, $suffix) = $self->_split($_p);
			$elem->setAttribute("xmlns:$prefix" => $expand);
			push @rv, "$prefix:$suffix";
		}
	}
	
	return join ' ', @rv;
}

sub _get_orig_node
{
	my $self = shift;
	my $node = shift;
	
	my @matches = $self->{'dom'}->documentElement->findnodes( $node->nodePath );
	return $matches[0];
}

sub _get_node_type
{
	my $self = shift;
	my $node = shift;
	
	return undef unless $node;
	return undef unless $node->nodeType == XML_ELEMENT_NODE;
	
	return $node->getAttribute('itemtype')
		if $node->hasAttribute('itemtype');
	
	return $self->_get_node_type($node->parentNode)
		if ($node != $self->{'dom'}->documentElement
		and defined $node->parentNode
		and $node->parentNode->nodeType == XML_ELEMENT_NODE);
	
	return undef;
}

sub _bnode
{
	my $self    = shift;
	my $rv      = sprintf('_:HTMLAutoNode%03d', $self->{bnodes}++);
	return $rv;
}

1;

__DATA__
dcterms	http://purl.org/dc/terms/
eg	http://example.com/
foaf	http://xmlns.com/foaf/0.1/
md	http://www.w3.org/1999/xhtml/microdata#
owl	http://www.w3.org/2002/07/owl#
rdf	http://www.w3.org/1999/02/22-rdf-syntax-ns#
rdfs	http://www.w3.org/2000/01/rdf-schema#
rss	http://purl.org/rss/1.0/
sioc	http://rdfs.org/sioc/ns#
skos	http://www.w3.org/2004/02/skos/core#
xhv	http://www.w3.org/1999/xhtml/vocab#
xsd	http://www.w3.org/2001/XMLSchema#
__END__

=back

=head1 BUGS

Please report any bugs to L<http://rt.cpan.org/>.

=head1 SEE ALSO

L<HTML::HTML5::Microdata::Parser>, L<RDF::RDFa::Parser>.

L<http://www.perlrdf.org/>.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT AND LICENCE

Copyright 2010 Toby Inkster

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
