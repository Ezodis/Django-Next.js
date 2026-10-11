const fs=require('node:fs'),path=require('node:path');
const {matchLocale,textKey,tokens}=require('./core.cjs');
const {createService}=require('./service.cjs');
function readCatalog(root,language,source){
 const locale=matchLocale(language);if(!locale)throw Error('Unsupported interface language');
 const file=path.join(root,'messages','automatic',locale+'.json');
 const saved=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{};
 /** @type {Record<string,string>} */
 const catalog={};
 for(const [id,text] of Object.entries(source)){
  const item=saved[id];
  if(item?.source===text&&typeof item.translation==='string'&&item.translation.trim()&&tokens(item.translation)===tokens(text))catalog[id]=item.translation;
 }
 return catalog;
}
async function prepareCatalog(root,language,source,{translate=createService({source}),persist=true}={}){
 const locale=matchLocale(language);if(!locale)throw Error('Unsupported interface language');
 const catalog=readCatalog(root,locale,source);
 const missing=Object.keys(source).filter(id=>textKey(source[id])===id&&!Object.hasOwn(catalog,id));
 for(let offset=0;offset<missing.length;offset+=35){
  Object.assign(catalog,await translate({language:locale,ids:missing.slice(offset,offset+35)}));
 }
 if(Object.keys(catalog).length!==Object.keys(source).length)throw Error('Incomplete interface dictionary');
 if(persist&&missing.length){
  const file=path.join(root,'messages','automatic',locale+'.json');
  const saved=Object.fromEntries(Object.entries(catalog).map(([id,translation])=>[id,{source:source[id],translation}]));
  fs.mkdirSync(path.dirname(file),{recursive:true});
  const temporary=file+'.'+process.pid+'.tmp';
  fs.writeFileSync(temporary,JSON.stringify(saved,null,2)+'\n');fs.renameSync(temporary,file);
 }
 return catalog;
}
module.exports={readCatalog,prepareCatalog};
