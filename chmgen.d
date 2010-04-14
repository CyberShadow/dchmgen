// D HTML to CHM converter/generator, by Vladimir Panteleev <thecybershadow@gmail.com>

import std.stdio;
import std.file;
import std.string;
import std.regexp;

// ********************************************************************

int min(int a, int b)
{
	return a < b ? a : b;
}

void backSlash(string s)   // replace path delimiters in-place
{
	//s=s.dup;
	foreach(inout c;s)
		if(c=='/')
			c='\\';
}

bool match(string line, string pattern)
{
	return std.regexp.find(line, pattern)>=0;
}

string getAnchor(string s)
{
	int i = std.string.find(s, '#');
	if(i<0)
		return "";
	else
		return s[i..$];
}

string removeAnchor(string s)
{
	int i = std.string.find(s, '#');
	if(i<0)
		return s;
	else
		return s[0..i];
}

string absoluteUrl(string base, string url)
{
	backSlash(base);
	backSlash(url);
	
	if (url[0]=='#')
		return base ~ url;

	while(base[$-1]!='\\')
		base = base[0..$-1];
	
	while(url[0..3]=="..\\")
	{
		url = url[3..$];
		do {
			base = base[0..$-1];
			if(base.length==0)
				return "";
		} while(base[$-1]!='\\');
	}
	return base ~ url;
}

string movePath(string s)
{
	if(s.length>1 && s[0..2]=="d\\")
		s = "chm" ~ s[1..$];
	return s;
}

string normalize(string s)
{
	s = tolower(s);
	string t;
	foreach(c;s)
		if(!iswhite(c))
			t ~= c;
	return t;
}

// ********************************************************************

struct Link
{
	string url, title, text;

	static Link opCall(string url, string title, string text)
	{
		backSlash(url);
		Link my;
		my.url = strip(url);
		my.title = strip(title);
		my.text = strip(text);
		return my;
	}
}

struct LinkBlock
{
	Link caption;
	Link[] links;

	static LinkBlock opCall(string url, string title, string text)
	{
		backSlash(url);
		LinkBlock my;
		my.caption.url = strip(url);
		my.caption.title = strip(title);
		my.caption.text = strip(text);
		return my;
	}
}

class Page
{
	string newFileName;
	string title;
	string src;
	Link[] toctop;
	LinkBlock[] linkBlocks;
	bool[string] anchors;
}

struct KeyLink
{
	string anchor;
	string title;

	static KeyLink opCall(string anchor, string title)
	{
		KeyLink my;
		my.anchor = strip(anchor);
		my.title = strip(title);
		return my;
	}
}

// ********************************************************************

string[] listdirrec(string pathname)
{
	string[] files = null;	

	bool listing(string filename)
	{
		string file = std.path.join(pathname, filename);
		if(isdir(file))
		{
			string oldpath = pathname;
			pathname = file;
			listdir(pathname, &listing);
			pathname = oldpath;
		}
		else
		{
			files ~= std.path.join(pathname, filename);
		}
		return true; // continue
	}
	
	listdir(pathname, &listing);

	return files;
}

Page[string] pages;
KeyLink[string][string] keywords;   // keywords[normalize(keyword)][original url w/o anchor] = anchor/title
string[string] keyTable;

void addKeyword(string keyword, string link, string title = null)
{
	keyword = strip(keyword);
	string norm = normalize(keyword);
	string file = removeAnchor(link);
	backSlash(file);
	string anchor = getAnchor(link);
	if(title==null && norm in keywords && file in keywords[norm])   // when title is present, it overrides any existing anchors/etc.
	{
		if(keywords[norm][file].anchor>anchor) // "less" is better
			keywords[norm][file] = KeyLink(anchor, title);
	}
	else
		keywords[norm][file] = KeyLink(anchor, title);
	if(title==null && norm in keyTable)
	{
		if(keyTable[norm]>keyword) // "less" is better
			keyTable[norm] = keyword;
	}
	else
		keyTable[norm] = keyword;
}

void main()
{
	// clean up
	if(exists("chm"))
		foreach(file;listdirrec("chm\\"))
			std.file.remove(file);
	else
		mkdir("chm");
	
	string[] files = listdirrec("d\\");
	
	foreach(i,file;files)
		pages[file] = new Page;

	RegExp re_title  = new RegExp(`<title>(.*) - (The )?D Programming Language( [0-9]\.[0-9])? - Digital Mars</title>`);
	RegExp re_title2 = new RegExp(`<title>(Digital Mars - The )?D Programming Language( [0-9]\.[0-9])? - (.*)</title>`);
	RegExp re_title3 = new RegExp(`<h1>(.*)</h1>`);
	RegExp re_heading = new RegExp(`<h2>(.*)</h2>`);
	RegExp re_heading_link = new RegExp(`<h2><a href="([^"]*)"( title="([^"]*)")?>(.*)</a></h2>`);
	RegExp re_nav_link = new RegExp(`<li><a href="([^"]*)"( title="(.*)")?>(.*)</a></li>`);
	RegExp re_anchor = new RegExp(`<a name="([^"]*)">(<.{1,2}>)*([^<]+)<`);
	RegExp re_anchor_2 = new RegExp(`<a name=([^>]*)>(<.{1,2}>)*([^<]+)<`);
	RegExp re_link   = new RegExp(`<a href="([^"]*)">(<.{1,2}>)*([^<]+)<`);
	RegExp re_def = new RegExp(`<dt><big>(.*)<u>([^<]+)<`);

	foreach(fileName,page;pages)
		with(page)
		{
			string destdir = movePath(std.path.getDirName(fileName));
			if(!exists(destdir))
				mkdir(destdir);

			newFileName = movePath(fileName);

			if(match(fileName, `\.html$`))
			{
				writefln("Processing "~fileName);
				src = cast(string)read(fileName);
				string[] lines = splitlines(src);
				string[] newlines = null;
				bool skip = false, intoctop = false, innavblock = false, innavblock2 = false;
				int dl = 0;
				string anchor = null;
				anchors[""] = true;
				foreach(origline;lines)
				{
					string line = origline;
					bool nextSkip = skip;
					
					if(match(line, `<li><a href="(http://www.digitalmars.com/d)?/?(\d\.\d)?/index.html" title="D Programming Language \d\.\d">`))
						continue; // don't process link as well
					
					line = line.replace("<ul>>", "<ul>");

					if (re_title.test(line))
					{
						title = strip(re_title.match(1));
						line = re_title.replace(`<title>` ~ title ~ `</title>`);
					}
					if (re_title2.test(line))
					{
						title = strip(re_title2.match(3));
						line = re_title2.replace(`<title>` ~ title ~ `</title>`);
					}
					if (re_title2.test(line))
						if(title=="")
							title = strip(re_title2.match(1));
					
					if (re_anchor.test(line))
					{
						anchor = '#' ~ re_anchor.match(1);
						anchors[anchor] = true;
					}
					else
					if (re_anchor_2.test(line))
					{
						anchor = '#' ~ re_anchor_2.match(1);
						anchors[anchor] = true;
					}

					if(match(line, `<div id="toctop">`))
						intoctop = true;
					if(match(line, `<div class="navblock">`))
						if(innavblock)
						{
							innavblock2 = true;
							linkBlocks ~= LinkBlock("", "", "");
						}
						else
							innavblock = true;
					if(match(line, `</div>`))
						intoctop = innavblock2 = false;

					if(std.string.find(line, `<dl>`)>=0)
						dl++;
					if(dl==1)
					{
						if(re_def.test(line))
						{
							anchor = re_def.match(2);
							while("#"~anchor in anchors) anchor ~= '_';
							anchors["#"~anchor] = true;
							line = re_def.pre ~ re_def.replace(`<dt><big>$1<u><a name="` ~ anchor ~ `">$2</a><`) ~ re_def.post;
							//writefln("new line: ", line);
							addKeyword(re_def.match(2), fileName ~ "#" ~ anchor);
						}
					}
					if(std.string.find(line, `</dl>`)>=0)
						dl--;

					if(re_heading_link.test(line))
					{
						if(innavblock2)
							linkBlocks ~= LinkBlock(re_heading_link.match(1), re_heading_link.match(3), re_heading_link.match(4));
					}
					else
					if(re_heading.test(line))
					{
						if(innavblock2)
							linkBlocks ~= LinkBlock("", "", re_heading.match(1));
					}

					if(re_nav_link.test(line))
						if(intoctop)
							toctop   ~= Link(re_nav_link.match(1), re_nav_link.match(3), re_nav_link.match(4));
						else
						if(innavblock2)
							if(re_nav_link.match(1)[0..7]!="http://" && exists(absoluteUrl(fileName, re_nav_link.match(1))))
								linkBlocks[$-1].links ~= Link(re_nav_link.match(1), re_nav_link.match(3), re_nav_link.match(4));
						//else
						//	writefln("Displaced link: ", line);
					
					if(re_anchor.test(line))
						addKeyword(re_anchor.match(3), fileName ~ "#" ~ re_anchor.match(1));
					else
					if(re_anchor_2.test(line))
						addKeyword(re_anchor_2.match(3), fileName ~ "#" ~ re_anchor_2.match(1));
					
					if(re_link.test(line))
						if(re_link.match(1)[0..min($,7)]!="http://")
							addKeyword(re_link.match(3), absoluteUrl(fileName, re_link.match(1)));
					
					// skip Google ads
					if(match(line, `^<!-- Google ad -->`))
						skip = nextSkip = true;
					if(match(line, `^</script>$`))
						nextSkip = false;

					// skip navigation bar
					if(match(line, `^<div id="navigation">$`))
						skip = nextSkip = true;
					if(match(line, `^<div id="content">$`))
						skip = nextSkip = false;

					// skip "digg this"
					if(match(line, `<script src="http://digg\.com/tools/diggthis\.js"`))
						skip = true;

					if(!skip)
						newlines ~= line;
					skip = nextSkip;
				}
				src = join(newlines, newline);
				write(newFileName, src);
			}
			else
			if(match(fileName, `\.css$`))
			{
				writefln("Processing "~fileName);
				src = cast(string)read(fileName);
				string[] lines = splitlines(src);
				string[] newlines = null;
				foreach(line;lines)
				{
					// skip #div.content positioning
					if(!match(line, `margin-left:\s*1[35]em;`))
						newlines ~= line;
				}
				src = join(newlines, newline);
				write(newFileName, src);
			}
			else
			{
				copy(fileName, newFileName);
			}
		} 

	// ************************************************************

	Link[] topLinks;
	bool[string] gotLink;

	foreach(fileName,page;pages)
		foreach(link;page.toctop)
		{
			string url = absoluteUrl(fileName, link.url);
			if(!(url in gotLink))
			{
				topLinks ~= Link(url, link.title, link.text);
				gotLink[url] = true;
			}
		}

	// retreive keyword link titles
	foreach(keyNorm,urls;keywords)
		foreach(url,inout link;urls)
			if(url in pages)
				link.title = pages[url].title;

	// ************************************************************

	RegExp re_key_new = new RegExp(`<tt>(.*)</tt>`);
	RegExp re_key_link = new RegExp(`^\* (.*)\[http://www\.digitalmars\.com/([^ ]*) (.*)\]`);

	string[] keywordLines = splitlines(keywordIndex);
	string keyword;
	foreach(line;keywordLines)
	{
		if(re_key_new.test(line))
			keyword = re_key_new.match(1);
		if(re_key_link.test(line))
		{
			string url = re_key_link.match(2);
			string file = removeAnchor(url);
			string anchor = getAnchor(url);
			backSlash(url);
			
			if(file in pages)
			{
				if(!(anchor in pages[file].anchors))
				{
					//string anchors; foreach(anch,b;pages[file].anchors) anchors~=anch~",";
					//writefln("Invalid URL: " ~ url ~ " out of: " ~ anchors);

					string cmp1 = normalize(anchor);
					foreach(realAnchor,b;pages[file].anchors)
					{
						string cmp2 = normalize(realAnchor);
						int n = min(cmp1.length, cmp2.length);
						if(n>=3 && cmp1[0..n] == cmp2[0..n])
						{
							//writefln("Fixing broken anchor " ~ anchor ~ " to " ~ realAnchor);
							anchor = realAnchor;
							break;
						}	
					}
				}

				if(anchor=="" || anchor in pages[file].anchors)
				{
					addKeyword(keyword, file ~ anchor, re_key_link.match(1) ~ re_key_link.match(3));
				//	writefln("Adding keyword " ~ keyword ~ " to " ~ file ~ anchor ~ " as " ~ re_key_link.match(1) ~ re_key_link.match(3));
				}
				//else
				//	writefln("Broken anchor link to keyword "~ keyword ~ " to " ~ re_key_link.match(2) ~ " as " ~ re_key_link.match(1) ~ re_key_link.match(3));
			}
			//else
			//	writefln("Unfound URL: " ~ url);
		}
	}

	// ************************************************************

	FILE* f = fopen("d.hhp", "wt");
	fwritefln(f, 
`[OPTIONS]
Binary Index=No
Compatibility=1.1 or later
Compiled file=d.chm
Contents file=d.hhc
Default Window=main
Default topic=` ~ movePath(topLinks[0].url) ~ `
Display compile progress=No
Full-text search=Yes
Index file=d.hhk
Language=0x409 English (United States)
Title=D

[WINDOWS]
main="D Programming Language","d.hhc","d.hhk","` ~ movePath(topLinks[0].url) ~ `","` ~ movePath(topLinks[0].url) ~ `",,,,,0x63520,,0x380e,[0,0,800,570],0x918f0000,,,,,,0

[FILES]`);
	string[] htmlList;
	foreach(page;pages)
		if(match(page.newFileName, `\.html$`))
			htmlList ~= page.newFileName;
	htmlList.sort;
	foreach(s;htmlList)
		fwritefln(f, s);
	fwritefln(f, `
[INFOTYPES]`);
	fclose(f);

	// ************************************************************

	f = fopen("d.hhc", "wt");
	fwritefln(f, 
`<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML//EN"><HTML><BODY>
<OBJECT type="text/site properties"><param name="Window Styles" value="0x800025"></OBJECT>
<UL>`);
	foreach(toplink;topLinks)
	{
		if(!(toplink.url in pages))
		{
			writefln("Warning: toplink ", toplink.text, " points to non-existing page ", toplink.url);
			continue;
		}
		fwritefln(f, 
`	<LI><OBJECT type="text/sitemap">
		<param name="Name" value="` ~ toplink.title ~ `">
		<param name="Local" value="` ~ movePath(toplink.url) ~ `">
		</OBJECT>
	<UL>`);
		Page topPage = pages[toplink.url];
		foreach(link;topPage.linkBlocks[0].links)
			fwritefln(f, 
`		<LI> <OBJECT type="text/sitemap">
			<param name="Name" value="` ~ link.text ~ `">
			<param name="Local" value="` ~ movePath(absoluteUrl(toplink.url, link.url)) ~ `">
			</OBJECT>`);
		foreach(linkBlock;topPage.linkBlocks[1..$])
		{
			fwritefln(f, 
`		<LI> <OBJECT type="text/sitemap">
			<param name="Name" value="` ~ linkBlock.caption.text ~ `">`);
			if(linkBlock.caption.url!="")
				fwritefln(f, 
`			<param name="Local" value="` ~ movePath(absoluteUrl(toplink.url, linkBlock.caption.url)) ~ `">`);
			fwritefln(f, 
`			</OBJECT>
		<UL>`);
			foreach(link;linkBlock.links)
				fwritefln(f, 
`			<LI> <OBJECT type="text/sitemap">
				<param name="Name" value="` ~ link.text ~ `">
				<param name="Local" value="` ~ movePath(absoluteUrl(toplink.url, link.url)) ~ `">
				</OBJECT>`);
			fwritefln(f, 
`		</UL>`);
		}
		fwritefln(f, 
`	</UL>`);
	}
	fwritefln(f, `</UL>
</BODY></HTML>`);
	fclose(f);

	// ************************************************************

	string[] keywordList;
	foreach(keyNorm,urlList;keywords)
		keywordList ~= keyNorm;
	keywordList.sort;

	f = fopen("d.hhk", "wt");
	fwritefln(f, 
`<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML//EN"><HTML><BODY>
<UL>`);
	foreach(keyNorm;keywordList)
	{
		auto urlList = keywords[keyNorm];
		fwritefln(f, 
`	<LI> <OBJECT type="text/sitemap">
		<param name="Name" value="` ~ keyTable[keyNorm] ~ `">`);
		foreach(url,link;urlList)
			if(url in pages)
			{
				fwritefln(f, 
`		<param name="Name" value="` ~ link.title ~ `">
		<param name="Local" value="` ~ movePath(url) ~ link.anchor ~ `">`);
			}
		fwritefln(f, 
`		</OBJECT>`);
	}
	fwritefln(f, 
`</UL>
</BODY></HTML>`);
	fclose(f);
}

// ********************************************************************

// retreived on 2007.11.08 from http://www.prowiki.org/wiki4d/wiki.cgi?LanguageSpecification/KeywordIndex
const keywordIndex = `
<tt>abstract</tt>
* [http://www.digitalmars.com/d/attribute.html#abstract Attributes]
<tt>alias</tt>
* [http://www.digitalmars.com/d/declaration.html#alias Declarations]
* template parameters: [http://www.digitalmars.com/d/template.html#aliasparameters Templates]
<tt>align</tt>
* [http://www.digitalmars.com/d/attribute.html#align Attributes]
<tt>asm</tt>
* [http://www.digitalmars.com/d/statement.html#asm Statements]
* x86 inline assembler:  [http://www.digitalmars.com/d/iasm.html Inline Assembler]
<tt>assert</tt>
* [http://www.digitalmars.com/d/expression.html#AssertExpression Expressions]
* static assert:  [http://www.digitalmars.com/d/version.html#staticassert Conditional Compilation]

<tt>auto</tt>
* class attribute:  [http://www.digitalmars.com/d/class.html#auto Classes]
* RAII attribute:  [http://www.digitalmars.com/d/attribute.html#auto Attributes]
* type inference:  [http://www.digitalmars.com/d/declaration.html#AutoDeclaration Declarations]

----

<tt>body</tt>
* in function contract:  [http://www.digitalmars.com/d/dbc.html Contracts]

<tt>bool</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>break</tt>
* in switch:  [http://www.digitalmars.com/d/statement.html#SwitchStatement Statements]
* statement:  [http://www.digitalmars.com/d/statement.html#BreakStatement Statements]

<tt>byte</tt>
* [http://www.digitalmars.com/d/type.html Types]

----

<tt>case</tt>
* in switch:  [http://www.digitalmars.com/d/statement.html#SwitchStatement Statements]

<tt>cast</tt>
* [http://www.digitalmars.com/d/expression.html#CastExpression Expressions]

<tt>catch</tt>
* [http://www.digitalmars.com/d/statement.html#TryStatement Statements]

<tt>cdouble</tt>
* [http://www.digitalmars.com/d/type.html Types]
* complex types:  [http://www.digitalmars.com/d/float.html Floating Point]

<tt>cent</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>cfloat</tt>
* [http://www.digitalmars.com/d/type.html Types]
* complex types:  [http://www.digitalmars.com/d/float.html Floating Point]

<tt>char</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>class</tt>
* [http://www.digitalmars.com/d/class.html Classes]
* properties of:  [http://www.digitalmars.com/d/property.html#classproperties Properties]

<tt>const</tt>
* [http://www.digitalmars.com/d/attribute.html#const Attributes]

<tt>continue</tt>
* [http://www.digitalmars.com/d/statement.html#ContinueStatement Statements]

<tt>creal</tt>
* [http://www.digitalmars.com/d/type.html Types]
* complex types:  [http://www.digitalmars.com/d/float.html Floating Point]

----

<tt>dchar</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>debug</tt>
* [http://www.digitalmars.com/d/version.html#debug Conditional Compilation]

<tt>default</tt>
* in switch:  [http://www.digitalmars.com/d/statement.html#SwitchStatement Statements]

<tt>delegate</tt>
* as datatype and replacement for pointer-to-member-function:  [http://www.digitalmars.com/d/type.html#delegates Types]
* as dynamic closure:  [http://www.digitalmars.com/d/function.html#closures Functions]
* in function literal:  [http://www.digitalmars.com/d/expression.html#FunctionLiteral Expressions]

<tt>delete</tt>
* expression:  [http://www.digitalmars.com/d/expression.html#DeleteExpression Expressions]
* overloading:  [http://www.digitalmars.com/d/class.html#deallocators Classes]

<tt>deprecated</tt>
* [http://www.digitalmars.com/d/attribute.html#deprecated Attributes]

<tt>do</tt>
* [http://www.digitalmars.com/d/statement.html#DoStatement Statements]

<tt>double</tt>
* [http://www.digitalmars.com/d/type.html Types]
* floating point types:  [http://www.digitalmars.com/d/float.html Floating Point]

----

<tt>else</tt>
* [http://www.digitalmars.com/d/statement.html#IfStatement Statements]

<tt>enum</tt>
* [http://www.digitalmars.com/d/enum.html Enums]

<tt>export</tt>
* protection attribute:  [http://www.digitalmars.com/d/attribute.html Attributes]

<tt>extern</tt>
* linkage attribute:  [http://www.digitalmars.com/d/attribute.html#linkage Attributes]
* interfacing to C:  [http://www.digitalmars.com/d/interfaceToC.html Interfacing to C]
* in variable declaration:  [http://www.digitalmars.com/d/declaration.html#extern Declarations]

----

<tt>false</tt>
* [http://www.digitalmars.com/d/expression.html#PrimaryExpression Expressions]

<tt>final</tt>
* [http://www.digitalmars.com/d/function.html Functions]

<tt>finally</tt>
* [http://www.digitalmars.com/d/statement.html#TryStatement Statements]

<tt>float</tt>
* [http://www.digitalmars.com/d/type.html Types]
* floating point types:  [http://www.digitalmars.com/d/float.html Floating Point]

<tt>for</tt>
* [http://www.digitalmars.com/d/statement.html#ForStatement Statements]

<tt>foreach</tt>
* [http://www.digitalmars.com/d/statement.html#ForeachStatement Statements]

<tt>foreach_reverse</tt>
* [http://www.digitalmars.com/d/statement.html#ForeachStatement Statements]

<tt>function</tt>
* as datatype:  [http://www.digitalmars.com/d/type.html Types]
* in function literal:  [http://www.digitalmars.com/d/expression.html#FunctionLiteral Expressions]
* function pointers:  [http://www.digitalmars.com/d/function.html#closures Functions]


----


<tt>goto</tt>
* [http://www.digitalmars.com/d/statement.html#GotoStatement Statements]


----


<tt>idouble</tt>
* [http://www.digitalmars.com/d/type.html Types]
* imaginary types:  [http://www.digitalmars.com/d/float.html Floating Point]

<tt>if</tt>
* [http://www.digitalmars.com/d/statement.html#IfStatement Statements]
* static if:  [http://www.digitalmars.com/d/version.html#staticif Conditional Compilation]

<tt>ifloat</tt>
* [http://www.digitalmars.com/d/type.html Types]
* imaginary types:  [http://www.digitalmars.com/d/float.html Floating Point]

<tt>import</tt>
* [http://www.digitalmars.com/d/module.html#ImportDeclaration Modules]
* import expression:  [http://digitalmars.com/d/expression.html#ImportExpression Expressions]

<tt>in</tt>
* in pre contract:  [http://www.digitalmars.com/d/dbc.html Contracts]
* containment test:  [http://www.digitalmars.com/d/expression.html#InExpression Expressions]
* function parameter:  [http://www.digitalmars.com/d/function.html#parameters Functions]

<tt>inout</tt> ''(deprecated, use <tt>ref</tt> instead)''
* in foreach statement:  [http://www.digitalmars.com/d/statement.html#ForeachStatement Statements]
* function parameter:  [http://www.digitalmars.com/d/function.html#parameters Functions]

<tt>int</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>interface</tt>
* [http://www.digitalmars.com/d/interface.html Interfaces]

<tt>invariant</tt>
* [http://www.digitalmars.com/d/class.html#invariants Classes]

<tt>ireal</tt>
* [http://www.digitalmars.com/d/type.html Types]
* imaginary types:  [http://www.digitalmars.com/d/float.html Floating Point]

<tt>is</tt>
* identity comparison:  [http://www.digitalmars.com/d/expression.html#EqualExpression Expressions]
* type comparison:  [http://www.digitalmars.com/d/expression.html#IsExpression Expressions]


----


<tt>lazy</tt>
* function parameter:  [http://www.digitalmars.com/d/function.html#parameters Functions]

<tt>long</tt>
* [http://www.digitalmars.com/d/type.html Types]


----

<tt>macro</tt>
* ''Unused''

<tt>mixin</tt>
* [http://www.digitalmars.com/d/template-mixin.html Template Mixins]
* Mixin declarations:  [http://digitalmars.com/d/module.html#MixinDeclaration Modules]
* Mixin expressions:  [http://digitalmars.com/d/expression.html#MixinExpression Expressions]
* Mixin statements:  [http://digitalmars.com/d/statement.html#MixinStatement Statements]

<tt>module</tt>
* [http://www.digitalmars.com/d/module.html Modules]


----


<tt>new</tt>
* anonymous nested classes and:  [http://www.digitalmars.com/d/class.html#anonymous Classes]
* expression:  [http://www.digitalmars.com/d/expression.html#NewExpression Expressions]
* overloading:  [http://www.digitalmars.com/d/class.html#allocators Classes]

<tt>null</tt>
* [http://www.digitalmars.com/d/expression.html#PrimaryExpression Expressions]


----


<tt>out</tt>
* in post contract:  [http://www.digitalmars.com/d/dbc.html Contracts]
* function parameter:  [http://www.digitalmars.com/d/function.html#parameters Functions]

<tt>override</tt>
* [http://www.digitalmars.com/d/attribute.html#override Attributes]


----


<tt>package</tt>
* [http://www.digitalmars.com/d/attribute.html Attributes]

<tt>pragma</tt>
* [http://www.digitalmars.com/d/pragma.html Pragmas]

<tt>private</tt>
* and import:  [http://www.digitalmars.com/d/module.html Modules]
* protection attribute:  [http://www.digitalmars.com/d/attribute.html Attributes]

<tt>protected</tt>
* [http://www.digitalmars.com/d/attribute.html Attributes]

<tt>public</tt>
* [http://www.digitalmars.com/d/attribute.html Attributes]


----


<tt>real</tt>
* [http://www.digitalmars.com/d/type.html Types]
* floating point types:  [http://www.digitalmars.com/d/float.html Floating Point]

<tt>ref</tt>
* in foreach statement:  [http://www.digitalmars.com/d/statement.html#ForeachStatement Statements]
* function parameter:  [http://www.digitalmars.com/d/function.html#parameters Functions]

<tt>return</tt>
* [http://www.digitalmars.com/d/statement.html#ReturnStatement Statements]


----


<tt>scope</tt>
* statement: [http://www.digitalmars.com/d/statement.html#ScopeGuardStatement Statements]
* RAII attribute:  [http://www.digitalmars.com/d/attribute.html#scope Attributes]

<tt>short</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>static</tt>
* attribute:  [http://www.digitalmars.com/d/attribute.html Attributes]
* constructors:  [http://www.digitalmars.com/d/class.html#staticconstructor Classes]
* destructors:  [http://www.digitalmars.com/d/class.html#staticdestructor Classes]
* order of static constructors and destructors:  [http://www.digitalmars.com/d/module.html#staticorder Modules]
* static assert:  [http://www.digitalmars.com/d/version.html#staticassert Conditional Compilation]
* static if:  [http://www.digitalmars.com/d/version.html#staticif Conditional Compilation]
* static import:  [http://www.digitalmars.com/d/module.html#ImportDeclaration Modules]

<tt>struct</tt>
* [http://www.digitalmars.com/d/struct.html Structs & Unions]
* properties of:  [http://www.digitalmars.com/d/property.html#classproperties Properties]

<tt>super</tt>
* [http://www.digitalmars.com/d/expression.html#PrimaryExpression Expressions]
* as name of superclass constructor:  [http://www.digitalmars.com/d/class.html#constructors Classes]

<tt>switch</tt>
* [http://www.digitalmars.com/d/statement.html#SwitchStatement Statements]

<tt>synchronized</tt>
* [http://www.digitalmars.com/d/statement.html#SynchronizedStatement Statements]


----


<tt>template</tt>
* [http://www.digitalmars.com/d/template.html Templates]

<tt>this</tt>
* [http://www.digitalmars.com/d/expression.html#PrimaryExpression Expressions]
* as constructor name:  [http://www.digitalmars.com/d/class.html#constructors Classes]
* with ~, as destructor name:  [http://www.digitalmars.com/d/class.html#destructors Classes]

<tt>throw</tt>
* [http://www.digitalmars.com/d/statement.html#ThrowStatement Statements]

<tt>__traits</tt>
* [http://www.digitalmars.com/d/traits.html Traits]

<tt>true</tt>
* [http://www.digitalmars.com/d/expression.html#PrimaryExpression Expressions]

<tt>try</tt>
* [http://www.digitalmars.com/d/statement.html#TryStatement Statements]

<tt>typedef</tt>
* [http://www.digitalmars.com/d/declaration.html#typedef Declarations]

<tt>typeid</tt>
* [http://www.digitalmars.com/d/expression.html#typeidexpression Expressions]

<tt>typeof</tt>
* [http://www.digitalmars.com/d/declaration.html#typeof Declarations]


----


<tt>ubyte</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>ucent</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>uint</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>ulong</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>union</tt>
* [http://www.digitalmars.com/d/struct.html Structs & Unions]

<tt>unittest</tt>
* in classes:  [http://www.digitalmars.com/d/class.html#unittest Classes]

<tt>ushort</tt>
* [http://www.digitalmars.com/d/type.html Types]


----


<tt>version</tt>
* [http://www.digitalmars.com/d/version.html#version Conditional Compilation]

<tt>void</tt>
* as initializer:  [http://www.digitalmars.com/d/declaration.html Declarations]
* as type:  [http://www.digitalmars.com/d/type.html Types]

<tt>volatile</tt>
* [http://www.digitalmars.com/d/statement.html#VolatileStatement Statements]


----


<tt>wchar</tt>
* [http://www.digitalmars.com/d/type.html Types]

<tt>while</tt>
* [http://www.digitalmars.com/d/statement.html#WhileStatement Statements]

<tt>with</tt>
* [http://www.digitalmars.com/d/statement.html#WithStatement Statements]



----

Source: Kirk <n>McDonald</n>, http://216.190.88.10:8087/media/d_index.html (NG:digitalmars.D/38550)
`;