const fs=require('node:fs'),path=require('node:path');
const {compile}=require('./compiler.cjs');
module.exports=function(source){
 this.cacheable();
 const result=compile(source,this.resourcePath);
 const file=path.join(this.rootContext,'messages','automatic-source.json');
 const catalog=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{};
 let changed=false;
 for(const [id,text]of Object.entries(result.messages)){if(catalog[id]&&catalog[id]!==text)throw Error('Translation key collision');if(catalog[id]!==text){catalog[id]=text;changed=true;}}
 if(changed){fs.mkdirSync(path.dirname(file),{recursive:true});const temporary=file+'.'+process.pid+'.'+require('node:crypto').randomUUID()+'.tmp';fs.writeFileSync(temporary,JSON.stringify(catalog,null,2)+'\n');fs.renameSync(temporary,file);}
 return result.code;
};
