lexer grammar YamlLexer;

// All comments that start with "///" are copy-pasted from
// The Python Language Reference: https://docs.python.org/3.3/reference/grammar.html

tokens { INDENT, DEDENT }

@lexer::members {
    /**
     * A queue where extra tokens are pushed on (see the NEWLINE lexer rule for instance).
     * Tokens are returned from the queue first. Once the queue is empty, lexer goes back to input stream for producing tokens.
     */
    private System.Collections.Generic.LinkedList<IToken> tokens = new System.Collections.Generic.LinkedList<IToken>();

    // The stack that keeps track of the indentation level.
    private System.Collections.Generic.Stack<int> indents = new System.Collections.Generic.Stack<int>();

    // The amount of opened braces, brackets and parenthesis.
    private int opened = 0;

    // The most recently produced token.
    private IToken lastToken = null;

    /**
     * Add a token to the queue. Tokens are returned from the queue first, before new tokens are extracted from input stream.
     */
    public void Schedule(IToken t) {
        tokens.AddLast(t);
    }

    public override IToken NextToken() {
        if (tokens.Count == 0) {
            IToken next = base.NextToken();

            if (next.Type == Eof) {
                ProcessEOF_NextToken();
                next = tokens.First.Value;
                tokens.RemoveFirst();
            } else if(next.Type == NEWLINE) {
                ProcessNEWLINE_NextToken();
                next = tokens.First.Value;
                tokens.RemoveFirst();
            } 

            if (lastToken != null && lastToken.Type == MINUS) {
                switch(next.Type) {
                    case MINUS:
                        next = CreateNewLine();
                        CreateAndScheduleIndent(this.TokenStartColumn);
                        Schedule(CommonToken(YamlParser.MINUS, "-"));
                        break;
                }
            }

            this.lastToken = next;
        } else {
            this.lastToken = tokens.First.Value;
            tokens.RemoveFirst();
        }

        return this.lastToken;
    }

    private void ProcessEOF_NextToken() {
        if (this.indents.Count > 0) {
            // Now emit as much DEDENT tokens as needed.
            while (indents.Count > 0) {
                this.Schedule(CreateDedent());
                indents.Pop();
            }
        }

        // Put the EOF back on the token stream.
        this.Schedule(CreateEof());
    }

    private void ProcessNEWLINE_NextToken() {
        var newline = CreateNewLine();
        var dedent = CreateDedent();
        
        int previous = indents.Count == 0 ? 0 : indents.Peek();

        IToken afterNext = base.NextToken();
        int indent = afterNext.Column;
        if(afterNext.Type == MINUS)
            indent+=2;

        if (indent == previous) {
            Schedule(newline);
        }
        else if (indent > previous && 
                // Add indentation for list item only after key: (support for sequences with no parent)
                (afterNext.Type != MINUS || lastToken.Type == COLON)) 
        {
            Schedule(newline);
            indents.Push(indent);
            Schedule(CreateIndent());
        }
        else {
            while(indents.Count > 0 && indents.Peek() > indent) {
                Schedule(dedent);
                indents.Pop();
            }
            Schedule(newline);
        }

        Schedule(afterNext);
    }

    private IToken CreateNewLine() {
        var token = new CommonToken(Tuple.Create<ITokenSource, ICharStream>(this, (ICharStream)InputStream), NEWLINE, DefaultTokenChannel, CharIndex, CharIndex -1);
        token.Line = this.lastToken.Line;
        token.Text = "\n";
        return token;
    }

    private IToken CreateDedent() {
        var token = new CommonToken(Tuple.Create<ITokenSource, ICharStream>(this, (ICharStream)InputStream), DEDENT, DefaultTokenChannel, CharIndex, CharIndex -1);
        token.Line = this.lastToken.Line;
        token.Text = "";
        return token;
    }

    private IToken CreateIndent() {
        var token = new CommonToken(Tuple.Create<ITokenSource, ICharStream>(this, (ICharStream)InputStream), INDENT, DefaultTokenChannel, CharIndex, CharIndex -1);
        token.Text = "";
        return token;
    }

    private IToken CreateEof() {
        var token = new CommonToken(Tuple.Create<ITokenSource, ICharStream>(this, (ICharStream)InputStream), Eof, DefaultTokenChannel, CharIndex, CharIndex -1);
        token.Text = "";
        return token;
    }

    private CommonToken CommonToken(int type, string text) {
        int stop = this.CharIndex - 1;
        int start = string.IsNullOrEmpty(text) ? stop : stop - text.Length + 1;
        return new CommonToken(Tuple.Create<ITokenSource, ICharStream>(this, (ICharStream)InputStream), type, DefaultTokenChannel, start, stop);
    }

    /**
     * Create a Indent token if given indentation level is greater and schedule it in 'tokens' queue.
     * @param indent indentation level
     */
    private void CreateAndScheduleIndent(int indent) {
        int previous = indents.Count == 0 ? 0 : indents.Peek();
        if (indent > previous) {
            indents.Push(indent);
            Schedule(CreateIndent());
        }
    }

    // Calculates the indentation of the provided spaces, taking the
    // following rules into account:
    //
    // "Tabs are replaced (from left to right) by one to eight spaces
    //  such that the total number of characters up to and including
    //  the replacement is a multiple of eight [...]"
    //
    //  -- https://docs.python.org/3.1/reference/lexical_analysis.html#indentation
    static int GetIndentationCount(string spaces) {
        int count = 0;

        foreach (char ch in spaces.ToCharArray()) {
            switch (ch) {
                case '\t':
                    count += 8 - (count % 8);
                    break;
                default:
                    // A normal space char.
                    count++;
                    break;
            }
        }

        return count;
    }

    bool AtStartOfInput() {
        return Column == 0 && Line == 1;
    }

    /**
     * Indentation of a string literal. '-1' means the value is not set.
     */
    private int string_literal_start = -1;
}


/*
 * lexer rules
 */

NEWLINE
 : ( {AtStartOfInput()}?   SPACES
   | ( '\r'? '\n' | '\r' ) SPACES?
   )
   {
     int next = ((ICharStream)InputStream).LA(1);
     if (opened > 0 || next == '\r' || next == '\n' || next == '#') {
         // If we're inside a list or on a blank line, ignore all indents,
         // dedents and line breaks.
         Skip();
     }
   }
 ;

/// bytesliteral   ::=  bytesprefix(shortbytes | longbytes)
/// bytesprefix    ::=  "b" | "B" | "br" | "Br" | "bR" | "BR"
BYTES_LITERAL
 : [bB] [rR]? ( SHORT_BYTES | LONG_BYTES )
 ;

/// decimalinteger ::=  nonzerodigit digit* | "0"+
DECIMAL_INTEGER
 : NON_ZERO_DIGIT DIGIT*
 | '0'+
 ;

/// octinteger     ::=  "0" ("o" | "O") octdigit+
OCT_INTEGER
 : '0' [oO] OCT_DIGIT+
 ;

/// hexinteger     ::=  "0" ("x" | "X") hexdigit+
HEX_INTEGER
 : '0' [xX] HEX_DIGIT+
 ;

/// bininteger     ::=  "0" ("b" | "B") bindigit+
BIN_INTEGER
 : '0' [bB] BIN_DIGIT+
 ;

/// floatnumber   ::=  pointfloat | exponentfloat
FLOAT_NUMBER
 : POINT_FLOAT
 | EXPONENT_FLOAT
 ;

/// imagnumber ::=  (floatnumber | intpart) ("j" | "J")
IMAG_NUMBER
 : ( FLOAT_NUMBER | INT_PART ) [jJ]
 ;

MINUS:              '-';
DOCUMENTSTART:      { Column == 0 }? '---';
DOCUMENTEND:        { Column == 0 }? '...';
AMPERSAND :         '&';
STAR :              '*';
OPEN_PAREN :        '(' {opened++;};
CLOSE_PAREN :       ')' {opened--;};
COMMA :             ',';
COLON :             ':';
OPEN_BRACK :        '[' {opened++;} -> pushMode(FLOW);
CLOSE_BRACK :       ']' {opened--;};
OPEN_BRACE :        '{' {opened++;}  -> pushMode(FLOW);
CLOSE_BRACE :       '}' {opened--;};
LITERIAL_STR_IND:   '|' {string_literal_start=-1;} -> pushMode(LITERAL_STRING);
FOLD_STR_IND:       '>' {string_literal_start=-1;} -> pushMode(LITERAL_STRING);
DOUBLE_QUOTE:       '"' -> pushMode(DOUBLE_QUOTE_STR);

ANCHOR
 : AMPERSAND NAME
 ;

ALIAS
 : STAR NAME
 ;

fragment NAME
 : [A-Za-z0-9]+
 ;

STRING_MY
 : STRING_MY_START (~(' '|'\r'|'\n'|'"'|':') | (':' ~[ \r\n]) | (' '+ ~[ :#\r\n]) )*
 ;

fragment STRING_MY_START
 : ~('-'|' '|'\r'|'\n'|'"'|':'|'#'|'['|'{'|'&'|'*'|'|') | (':' ~[ \r\n]) | ('-' ~[ \-\r\n]) | {((ICharStream)InputStream).LA(3) != 45}? '--' | {Column != 0}? '---'
 ;

SKIP1
 : ( SPACES | COMMENT | LINE_JOINING ) -> skip
 ;

UNKNOWN_CHAR
 : .
 ;

/*
 * fragments
 */

/// nonzerodigit   ::=  "1"..."9"
fragment NON_ZERO_DIGIT
 : [1-9]
 ;

/// digit          ::=  "0"..."9"
fragment DIGIT
 : [0-9]
 ;

/// octdigit       ::=  "0"..."7"
fragment OCT_DIGIT
 : [0-7]
 ;

/// hexdigit       ::=  digit | "a"..."f" | "A"..."F"
fragment HEX_DIGIT
 : [0-9a-fA-F]
 ;

/// bindigit       ::=  "0" | "1"
fragment BIN_DIGIT
 : [01]
 ;

/// pointfloat    ::=  [intpart] fraction | intpart "."
fragment POINT_FLOAT
 : INT_PART? FRACTION
 | INT_PART '.'
 ;

/// exponentfloat ::=  (intpart | pointfloat) exponent
fragment EXPONENT_FLOAT
 : ( INT_PART | POINT_FLOAT ) EXPONENT
 ;

/// intpart       ::=  digit+
fragment INT_PART
 : DIGIT+
 ;

/// fraction      ::=  "." digit+
fragment FRACTION
 : '.' DIGIT+
 ;

/// exponent      ::=  ("e" | "E") ["+" | "-"] digit+
fragment EXPONENT
 : [eE] [+-]? DIGIT+
 ;

/// shortbytes     ::=  "'" shortbytesitem* "'" | '"' shortbytesitem* '"'
/// shortbytesitem ::=  shortbyteschar | bytesescapeseq
fragment SHORT_BYTES
 : '\'' ( SHORT_BYTES_CHAR_NO_SINGLE_QUOTE | BYTES_ESCAPE_SEQ )* '\''
 | '"' ( SHORT_BYTES_CHAR_NO_DOUBLE_QUOTE | BYTES_ESCAPE_SEQ )* '"'
 ;

/// longbytes      ::=  "'''" longbytesitem* "'''" | '"""' longbytesitem* '"""'
fragment LONG_BYTES
 : '\'\'\'' LONG_BYTES_ITEM*? '\'\'\''
 | '"""' LONG_BYTES_ITEM*? '"""'
 ;

/// longbytesitem  ::=  longbyteschar | bytesescapeseq
fragment LONG_BYTES_ITEM
 : LONG_BYTES_CHAR
 | BYTES_ESCAPE_SEQ
 ;

/// shortbyteschar ::=  <any ASCII character except "\" or newline or the quote>
fragment SHORT_BYTES_CHAR_NO_SINGLE_QUOTE
 : [\u0000-\u0009]
 | [\u000B-\u000C]
 | [\u000E-\u0026]
 | [\u0028-\u005B]
 | [\u005D-\u007F]
 ;

fragment SHORT_BYTES_CHAR_NO_DOUBLE_QUOTE
 : [\u0000-\u0009]
 | [\u000B-\u000C]
 | [\u000E-\u0021]
 | [\u0023-\u005B]
 | [\u005D-\u007F]
 ;

/// longbyteschar  ::=  <any ASCII character except "\">
fragment LONG_BYTES_CHAR
 : [\u0000-\u005B]
 | [\u005D-\u007F]
 ;

/// bytesescapeseq ::=  "\" <any ASCII character>
fragment BYTES_ESCAPE_SEQ
 : '\\' [\u0000-\u007F]
 ;

fragment SPACES
 : [ \t]+
 ;

fragment COMMENT
 : '#' ~[\r\n]*
 ;

fragment LINE_JOINING
 : '\\' SPACES? ( '\r'? '\n' | '\r' )
 ;

// MODE CHANGE
mode FLOW;

// decimalinteger ::=  nonzerodigit digit* | "0"+
DECIMAL_INTEGER2
 : (NON_ZERO_DIGIT DIGIT*
 | '0'+)                     -> type(DECIMAL_INTEGER)
 ;

/// octinteger     ::=  "0" ("o" | "O") octdigit+
OCT_INTEGER2
 : '0' [oO] OCT_DIGIT+      -> type(OCT_INTEGER)
 ;

/// hexinteger     ::=  "0" ("x" | "X") hexdigit+
HEX_INTEGER2
 : '0' [xX] HEX_DIGIT+      -> type(HEX_INTEGER)
 ;

/// bininteger     ::=  "0" ("b" | "B") bindigit+
BIN_INTEGER2
 : '0' [bB] BIN_DIGIT+      -> type(BIN_INTEGER)
 ;

/// floatnumber   ::=  pointfloat | exponentfloat
FLOAT_NUMBER2
 : (POINT_FLOAT
 | EXPONENT_FLOAT)           -> type(FLOAT_NUMBER)
 ;

/// imagnumber ::=  (floatnumber | intpart) ("j" | "J")
IMAG_NUMBER2
 : ( FLOAT_NUMBER | INT_PART ) [jJ]     -> type(IMAG_NUMBER)
 ;

STRING_MY_2
 : STRING_MY_START_2 (~(' '|'\r'|'\n'|'"'|':'|'['|']'|','|'{'|'}') | (':' ~[ \r\n]) | (' '+ ~(' '|':'|'#'|'\r'|'\n'|'['|']'|','|'{'|'}')) )* -> type(STRING_MY)
 ;

fragment STRING_MY_START_2
 : ~('-'|' '|'\r'|'\n'|'"'|':'|'#'|'['|']'|','|'{'|'}') | (':' ~[ \r\n]) | ('-' ~[ \r\n])
 ;

COMMA2
 : ',' -> type(COMMA)
 ;

COLON2
 : ':' -> type(COLON)
 ;

SKIP2
 : ( SPACES | COMMENT | LINE_JOINING | ( '\r'? '\n' | '\r' )) -> skip
 ;

CLOSE_BRACK2
 : ']'  -> type(CLOSE_BRACK), popMode
 ;

CLOSE_BRACE2
 : '}'  -> type(CLOSE_BRACE), popMode
 ;

// MODE CHANGE
mode LITERAL_STRING;

NEWLINE_STR_LITERAL: ( '\r'? '\n' | '\r' ) [ \t]*
   {
     int next = ((ICharStream)InputStream).LA(1);
     if(!(opened > 0 || next == '\r' || next == '\n' || next == '#')) {
       int indent = indents.Count == 0 ? 0 : indents.Peek();
       int space_count = GetIndentationCount(Text.Replace("\r\n", "").Replace("\n", ""));
       if(space_count <= indent) {
         PopMode();
         Type = NEWLINE;
       }
       else if (string_literal_start == -1) {
         string_literal_start = space_count;
       }
     }
   }
 ;
 //shouldn't do ->type(NEWLINE) to avoid NEWLINE post processing

STRING_MY_3
 : ~('\r'|'\n')*
   {
     int extraSpace = TokenStartColumn - string_literal_start;
     if(extraSpace > 0) {
       System.Text.StringBuilder builder = new System.Text.StringBuilder();
       for (int i = 0; i < extraSpace; i++) {
         builder.Append(' ');
       }
       builder.Append(Text);
       Text = builder.ToString();
     }
   }
   -> type(STRING_MY)
 ;


// MODE CHANGE
mode DOUBLE_QUOTE_STR;

STRING_MY_4
 : (~["\r\n\\] | '\\\\')*
   -> type(STRING_MY)
 ;

NEWLINE_STR_QUOTE: ( '\r'? '\n' | '\r' ) [ \t]* ;

DOUBLE_QUOTE2: '"' -> type(DOUBLE_QUOTE), popMode;