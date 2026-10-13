const fs=require('node:fs'),path=require('node:path');
const {compile}=require('./compiler.cjs');
const {textKey}=require('./core.cjs');
function prepare(root,{check=false}={}){
 const file=path.join(root,'messages','automatic-source.json');
 const catalog=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{};
 const walk=directory=>{if(!fs.existsSync(directory))return;for(const entry of fs.readdirSync(directory,{withFileTypes:true})){
  const filename=path.join(directory,entry.name);
  if(entry.isDirectory())walk(filename);
  else if(/\.[jt]sx?$/.test(entry.name)&&!/\.(test|spec)\./.test(entry.name))for(const [id,text]of Object.entries(compile(fs.readFileSync(filename,'utf8'),filename).messages)){
   if(catalog[id]&&catalog[id]!==text)throw Error('Translation key collision');catalog[id]=text;
  }
 }};
 for(const directory of ['app','components'])walk(path.join(root,directory));
 const options=JSON.parse(fs.readFileSync(path.join(root,'package.json'),'utf8')).localization??{};
 const preserve=new Set(options.preserve??[]);
 const collect=value=>{
  if(Array.isArray(value))value.forEach(collect);
  else if(value&&typeof value==='object')for(const [name,text]of Object.entries(value)){
   if(['name','title','label','description'].includes(name)&&typeof text==='string'&&!preserve.has(text.trim()))catalog[textKey(text)]=text;
   else if(text&&typeof text==='object')collect(text);
  }
 };
 for(const relative of options.catalogs??[]){const target=path.resolve(root,relative);if(path.relative(root,target).startsWith('..')||path.isAbsolute(path.relative(root,target)))throw Error('Interface catalog must be inside this project');collect(JSON.parse(fs.readFileSync(target,'utf8')));}
 for(const [id,text]of Object.entries(catalog))if(preserve.has(text.trim()))delete catalog[id];
 if(check){
  const saved=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{};
  const unregistered=Object.entries(catalog).filter(([id,text])=>saved[id]!==text);
  const {readCatalog}=require('./catalog.cjs'),{locales}=require('./core.cjs');
  const failures=[];
  for(const locale of locales){const count=Object.keys(catalog).length-Object.keys(readCatalog(root,locale,catalog)).length;if(count)failures.push(locale+': '+count);}
  if(unregistered.length||failures.length)throw Error('Interface coverage incomplete: '+unregistered.length+' unregistered phrases; missing translations ['+failures.join(', ')+']. Run node localization/prepare.cjs --translations and commit the generated dictionaries.');
  return Object.keys(catalog).length;
 }
 fs.mkdirSync(path.dirname(file),{recursive:true});
 const content=JSON.stringify(catalog,null,2)+'\n';
 if(!fs.existsSync(file)||fs.readFileSync(file,'utf8')!==content){const temporary=file+'.'+process.pid+'.'+require('node:crypto').randomUUID()+'.tmp';fs.writeFileSync(temporary,content);fs.renameSync(temporary,file);}
 return Object.keys(catalog).length;
}
async function prepareTranslations(root,languages=require('./core.cjs').locales){
 prepare(root);
 const source=JSON.parse(fs.readFileSync(path.join(root,'messages','automatic-source.json'),'utf8'));
 const {prepareCatalog}=require('./catalog.cjs');
 const queue=[...languages];
 const failures=[];
 await Promise.all(Array.from({length:4},async()=>{while(queue.length){const locale=queue.shift();try{await prepareCatalog(root,locale,source);console.log('Interface dictionary ready: '+locale);}catch(error){failures.push(locale+': '+error.message);}}}));
 if(failures.length)throw Error(failures.join('\n'));
}
const verify=root=>prepare(root,{check:true});
module.exports={prepare,prepareTranslations,verify};
if(require.main===module){
 const root=path.resolve(__dirname,'..');
 if(process.argv.includes('--check')){try{console.log(`${verify(root)} interface phrases verified in every supported language`);}catch(error){console.error(error.message);process.exitCode=1;}}
 else console.log(`${prepare(root)} automatic interface phrases`);
 if(process.argv.includes('--translations'))prepareTranslations(root).catch(error=>{console.error(error.message);process.exitCode=1;});
}
