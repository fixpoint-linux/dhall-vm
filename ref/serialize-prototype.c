/* Verification prototype: value-tree + JSON/YAML/TOML emitters.
   Proven by the consultant against the real dhall.com.dbg outputs.
   Transcribe value_to_json/value_to_yaml/value_to_toml + yaml_plain_ok +
   toml_key + dbl_marker/qstr into src/serialize.c, swapping malloc/strdup ->
   arena_alloc/arena_strdup and threading DhallError* instead of the
   toml_err flag / <ERR:...> placeholders. The driver main() is scratch. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <ctype.h>

typedef enum { VK_NULL, VK_NAT, VK_INT, VK_DBL, VK_BOOL, VK_TEXT, VK_ARRAY, VK_TABLE } ValueKind;
typedef struct Value Value;
struct Value {
    ValueKind kind;
    union {
        uint64_t nat; int64_t i64; double dbl; bool b; char *text;
        struct { Value **items; int n; } arr;
        struct { char **keys; Value **vals; int n; } tab;
    } as;
};
static Value *vnull(void){ Value*v=calloc(1,sizeof *v); v->kind=VK_NULL; return v; }
static Value *vnat(uint64_t n){ Value*v=calloc(1,sizeof *v); v->kind=VK_NAT; v->as.nat=n; return v; }
static Value *vint(int64_t n){ Value*v=calloc(1,sizeof *v); v->kind=VK_INT; v->as.i64=n; return v; }
static Value *vdbl(double d){ Value*v=calloc(1,sizeof *v); v->kind=VK_DBL; v->as.dbl=d; return v; }
static Value *vbool(bool b){ Value*v=calloc(1,sizeof *v); v->kind=VK_BOOL; v->as.b=b; return v; }
static Value *vtext(const char*s){ Value*v=calloc(1,sizeof *v); v->kind=VK_TEXT; v->as.text=strdup(s); return v; }
static Value *varr(Value **items, int n){ Value*v=calloc(1,sizeof *v); v->kind=VK_ARRAY; v->as.arr.items=items; v->as.arr.n=n; return v; }
static Value *vtab(char **keys, Value **vals, int n){ Value*v=calloc(1,sizeof *v); v->kind=VK_TABLE; v->as.tab.keys=keys; v->as.tab.vals=vals; v->as.tab.n=n; return v; }
/* shared double-quoted escaper (JSON basic string / TOML basic string / YAML dq) */
static void qstr(FILE*out, const char*s){
    fputc('"',out);
    for(const unsigned char*p=(const unsigned char*)s; *p; p++){
        switch(*p){
        case '"': fputs("\\\"",out); break;
        case '\\': fputs("\\\\",out); break;
        case '\b': fputs("\\b",out); break;
        case '\f': fputs("\\f",out); break;
        case '\n': fputs("\\n",out); break;
        case '\r': fputs("\\r",out); break;
        case '\t': fputs("\\t",out); break;
        default: if(*p<0x20) fprintf(out,"\\u%04x",*p); else fputc(*p,out);
        }
    }
    fputc('"',out);
}
/* finite float with a forced '.', 'e', or 'E' so TOML/YAML read it as float */
static void dbl_marker(FILE*out, double d){
    char buf[64]; snprintf(buf,sizeof buf,"%g",d);
    fputs(buf,out);
    if(!strpbrk(buf,".eE")) fputs(".0",out);
}
static void dbl_json(FILE*out,double d){ if(!isfinite(d)) fputs("null",out); else { char b[64]; snprintf(b,sizeof b,"%g",d); fputs(b,out); } }
static void dbl_yaml(FILE*out,double d){ if(isnan(d)) fputs(".nan",out); else if(d==INFINITY) fputs(".inf",out); else if(d==-INFINITY) fputs("-.inf",out); else dbl_marker(out,d); }
static void dbl_toml(FILE*out,double d){ if(isnan(d)) fputs("nan",out); else if(d==INFINITY) fputs("inf",out); else if(d==-INFINITY) fputs("-inf",out); else dbl_marker(out,d); }
static void toml_key(FILE*out, const char*k){
    bool bare = *k != '\0';
    if (bare) for(const unsigned char*p=(const unsigned char*)k;*p;p++) if(!(isalnum(*p)||*p=='_'||*p=='-')){bare=false;break;}
    if (bare && (!strcmp(k,"true")||!strcmp(k,"false")||!strcmp(k,"inf")||!strcmp(k,"nan"))) bare=false;
    if (bare) fputs(k,out); else qstr(out,k);
}
static void yaml_ind(FILE*out,int n){ for(int i=0;i<n;i++) fputc(' ',out); }
static bool yaml_plain_ok(const char*s){
    if(!s || !*s) return false;
    if(*s==' '||*s=='\t') return false;
    const char*lead = "-?:,[]{}#&*!|>'\"%@`";
    if(strchr(lead,*s)) return false;
    size_t n=strlen(s);
    if(s[n-1]==' '||s[n-1]=='\t') return false;
    if(strchr(s,'\n')||strchr(s,'\t')) return false;
    if(strstr(s,": ")||strstr(s," #")) return false;
    for(const unsigned char*p=(const unsigned char*)s;*p;p++) if(*p<0x20) return false;
    static const char*res[]={"null","~","true","false","True","False","TRUE","FALSE","Null","NULL"};
    for(unsigned i=0;i<sizeof res/sizeof *res;i++) if(!strcmp(s,res[i])) return false;
    char*end; (void)strtod(s,&end); if(end && *end=='\0' && end!=s) return false;
    return true;
}
static void yaml_scalar(FILE*out,const Value*v){
    switch(v->kind){
    case VK_NULL: fputs("null",out); break;
    case VK_NAT: fprintf(out,"%llu",(unsigned long long)v->as.nat); break;
    case VK_INT: fprintf(out,"%lld",(long long)v->as.i64); break;
    case VK_DBL: dbl_yaml(out,v->as.dbl); break;
    case VK_BOOL: fputs(v->as.b?"true":"false",out); break;
    case VK_TEXT: if(yaml_plain_ok(v->as.text)) fputs(v->as.text,out); else qstr(out,v->as.text); break;
    default: break;
    }
}
static void yaml_key(FILE*out,const char*k){ if(yaml_plain_ok(k)) fputs(k,out); else qstr(out,k); }
static bool yaml_is_scalar(const Value*v){ return v->kind!=VK_ARRAY && v->kind!=VK_TABLE; }
static bool yaml_is_empty(const Value*v){ return (v->kind==VK_ARRAY&&v->as.arr.n==0)||(v->kind==VK_TABLE&&v->as.tab.n==0); }
static void yaml_emit(FILE*out,const Value*v,int ind);
static void yaml_emit_field(FILE*out,const char*key,const Value*val,int ind){
    yaml_ind(out,ind); yaml_key(out,key); fputc(':',out);
    if (yaml_is_scalar(val)){ fputc(' ',out); yaml_scalar(out,val); fputc('\n',out); }
    else if (yaml_is_empty(val)){ fputc(' ',out); fputs(val->kind==VK_ARRAY?"[]":"{}",out); fputc('\n',out); }
    else { fputc('\n',out); yaml_emit(out,val,ind+2); }
}
static void yaml_emit(FILE*out,const Value*v,int ind){
    switch(v->kind){
    case VK_ARRAY:
        if(v->as.arr.n==0){ fputs("[]",out); break; }
        for(int i=0;i<v->as.arr.n;i++){
            const Value*it=v->as.arr.items[i];
            if(yaml_is_scalar(it)){ yaml_ind(out,ind); fputs("- ",out); yaml_scalar(out,it); fputc('\n',out); }
            else if(yaml_is_empty(it)){ yaml_ind(out,ind); fputs("- ",out); fputs(it->kind==VK_ARRAY?"[]":"{}",out); fputc('\n',out); }
            else if(it->kind==VK_TABLE){
                yaml_ind(out,ind); fputs("- ",out);
                yaml_key(out,it->as.tab.keys[0]); fputc(':',out);
                const Value*fv=it->as.tab.vals[0];
                if(yaml_is_scalar(fv)){ fputc(' ',out); yaml_scalar(out,fv); fputc('\n',out); }
                else if(yaml_is_empty(fv)){ fputc(' ',out); fputs(fv->kind==VK_ARRAY?"[]":"{}",out); fputc('\n',out); }
                else { fputc('\n',out); yaml_emit(out,fv,ind+4); }
                for(int j=1;j<it->as.tab.n;j++) yaml_emit_field(out,it->as.tab.keys[j],it->as.tab.vals[j],ind+2);
            } else { yaml_ind(out,ind); fputs("-\n",out); yaml_emit(out,it,ind+2); }
        }
        break;
    case VK_TABLE:
        if(v->as.tab.n==0){ fputs("{}",out); break; }
        for(int i=0;i<v->as.tab.n;i++) yaml_emit_field(out,v->as.tab.keys[i],v->as.tab.vals[i],ind);
        break;
    default: yaml_scalar(out,v); break;
    }
}
static void toml_value(FILE*out,const Value*v){
    switch(v->kind){
    case VK_NAT: fprintf(out,"%llu",(unsigned long long)v->as.nat); break;
    case VK_INT: fprintf(out,"%lld",(long long)v->as.i64); break;
    case VK_DBL: dbl_toml(out,v->as.dbl); break;
    case VK_BOOL: fputs(v->as.b?"true":"false",out); break;
    case VK_TEXT: qstr(out,v->as.text); break;
    case VK_NULL: fputs("<ERR:null>",out); break; /* replace with DhallError* propagation */
    case VK_ARRAY: {
        fputc('[',out);
        for(int i=0;i<v->as.arr.n;i++){ if(i) fputs(", ",out); toml_value(out,v->as.arr.items[i]); }
        fputc(']',out); break;
    }
    case VK_TABLE: {
        fputs("{ ",out);
        for(int i=0;i<v->as.tab.n;i++){ if(i) fputs(", ",out); toml_key(out,v->as.tab.keys[i]); fputs(" = ",out); toml_value(out,v->as.tab.vals[i]); }
        fputs(" }",out); break;
    }
    }
}
static void toml_table(FILE*out,const Value*v,const char*prefix){
    for(int i=0;i<v->as.tab.n;i++)
        if(v->as.tab.vals[i]->kind!=VK_TABLE){ toml_key(out,v->as.tab.keys[i]); fputs(" = ",out); toml_value(out,v->as.tab.vals[i]); fputc('\n',out); }
    for(int i=0;i<v->as.tab.n;i++)
        if(v->as.tab.vals[i]->kind==VK_TABLE){
            char hdr[512]; snprintf(hdr,sizeof hdr,"%s%s",prefix,v->as.tab.keys[i]);
            fprintf(out,"[%s]\n",hdr);
            char np[512]; snprintf(np,sizeof np,"%s.",hdr);
            toml_table(out,v->as.tab.vals[i],np);
        }
}
static void toml_emit(FILE*out,const Value*v){
    if(v->kind!=VK_TABLE){ fputs("<ERR: top-level must be a record>\n",out); return; } /* replace with DhallError* */
    toml_table(out,v,"");
}
static void json_value(FILE*out,const Value*v){
    switch(v->kind){
    case VK_NULL: fputs("null",out); break;
    case VK_NAT: fprintf(out,"%llu",(unsigned long long)v->as.nat); break;
    case VK_INT: fprintf(out,"%lld",(long long)v->as.i64); break;
    case VK_DBL: dbl_json(out,v->as.dbl); break;
    case VK_BOOL: fputs(v->as.b?"true":"false",out); break;
    case VK_TEXT: qstr(out,v->as.text); break;
    case VK_ARRAY:
        fputc('[',out); for(int i=0;i<v->as.arr.n;i++){ if(i) fputc(',',out); json_value(out,v->as.arr.items[i]); } fputc(']',out); break;
    case VK_TABLE:
        fputc('{',out); for(int i=0;i<v->as.tab.n;i++){ if(i) fputc(',',out); qstr(out,v->as.tab.keys[i]); fputc(':',out); json_value(out,v->as.tab.vals[i]); } fputc('}',out); break;
    }
}
