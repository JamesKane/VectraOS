/* A Bison parser, made by GNU Bison 3.8.2.  */

/* Bison interface for Yacc-like parsers in C

   Copyright (C) 1984, 1989-1990, 2000-2015, 2018-2021 Free Software Foundation,
   Inc.

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>.  */

/* As a special exception, you may create a larger work that contains
   part or all of the Bison parser skeleton and distribute that work
   under terms of your choice, so long as that work isn't itself a
   parser generator using the skeleton or a modified version thereof
   as a parser skeleton.  Alternatively, if you modify or redistribute
   the parser skeleton itself, you may (at your option) remove this
   special exception, which will cause the skeleton and the resulting
   Bison output files to be licensed under the GNU General Public
   License without this special exception.

   This special exception was added by the Free Software Foundation in
   version 2.2 of Bison.  */

/* DO NOT RELY ON FEATURES THAT ARE NOT DOCUMENTED in the manual,
   especially those whose name start with YY_ or yy_.  They are
   private implementation details that can be changed or removed.  */

#ifndef YY_YY_Y_TAB_H_INCLUDED
# define YY_YY_Y_TAB_H_INCLUDED
/* Debug traces.  */
#ifndef YYDEBUG
# define YYDEBUG 0
#endif
#if YYDEBUG
extern int yydebug;
#endif

/* Token kinds.  */
#ifndef YYTOKENTYPE
# define YYTOKENTYPE
  enum yytokentype
  {
    YYEMPTY = -2,
    YYEOF = 0,                     /* "end of file"  */
    YYerror = 256,                 /* error  */
    YYUNDEF = 257,                 /* "invalid token"  */
    FOR = 258,                     /* FOR  */
    IN = 259,                      /* IN  */
    WHILE = 260,                   /* WHILE  */
    IF = 261,                      /* IF  */
    NOT = 262,                     /* NOT  */
    TWIDDLE = 263,                 /* TWIDDLE  */
    BANG = 264,                    /* BANG  */
    SUBSHELL = 265,                /* SUBSHELL  */
    SWITCH = 266,                  /* SWITCH  */
    FN = 267,                      /* FN  */
    WORD = 268,                    /* WORD  */
    REDIR = 269,                   /* REDIR  */
    DUP = 270,                     /* DUP  */
    PIPE = 271,                    /* PIPE  */
    SUB = 272,                     /* SUB  */
    SIMPLE = 273,                  /* SIMPLE  */
    ARGLIST = 274,                 /* ARGLIST  */
    WORDS = 275,                   /* WORDS  */
    BRACE = 276,                   /* BRACE  */
    PAREN = 277,                   /* PAREN  */
    PCMD = 278,                    /* PCMD  */
    PIPEFD = 279,                  /* PIPEFD  */
    ANDAND = 280,                  /* ANDAND  */
    OROR = 281,                    /* OROR  */
    COUNT = 282                    /* COUNT  */
  };
  typedef enum yytokentype yytoken_kind_t;
#endif
/* Token kinds.  */
#define YYEMPTY -2
#define YYEOF 0
#define YYerror 256
#define YYUNDEF 257
#define FOR 258
#define IN 259
#define WHILE 260
#define IF 261
#define NOT 262
#define TWIDDLE 263
#define BANG 264
#define SUBSHELL 265
#define SWITCH 266
#define FN 267
#define WORD 268
#define REDIR 269
#define DUP 270
#define PIPE 271
#define SUB 272
#define SIMPLE 273
#define ARGLIST 274
#define WORDS 275
#define BRACE 276
#define PAREN 277
#define PCMD 278
#define PIPEFD 279
#define ANDAND 280
#define OROR 281
#define COUNT 282

/* Value type.  */
#if ! defined YYSTYPE && ! defined YYSTYPE_IS_DECLARED
union YYSTYPE
{
#line 16 "syn.y"

	struct tree *tree;

#line 125 "y.tab.h"

};
typedef union YYSTYPE YYSTYPE;
# define YYSTYPE_IS_TRIVIAL 1
# define YYSTYPE_IS_DECLARED 1
#endif


extern YYSTYPE yylval;


int yyparse (void);


#endif /* !YY_YY_Y_TAB_H_INCLUDED  */
