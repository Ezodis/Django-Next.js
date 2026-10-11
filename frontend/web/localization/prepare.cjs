const fs=require('node:fs'),path=require('node:path');
const {compile}=require('./compiler.cjs');
const {textKey}=require('./core.cjs');
function prepare(root){
 const file=path.join(root,'messages','automatic-source.json');
 const catalog=fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):{};
 const walk=directory=>{if(!fs.existsSync(directory))return;for(const entry of fs.readdirSync(directory,{withFileTypes:true})){
  const filename=path.join(directory,entry.name);
  if(entry.isDirectory())walk(filename);
  else if(/\.tsx$/.test(entry.name)&&!/\.test\./.test(entry.name))for(const [id,text]of Object.entries(compile(fs.readFileSync(filename,'utf8'),filename).messages)){
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
 fs.mkdirSync(path.dirname(file),{recursive:true});
 const content=JSON.stringify(catalog,null,2)+'\n';
 if(!fs.existsSync(file)||fs.readFileSync(file,'utf8')!==content)fs.writeFileSync(file,content);
 return Object.keys(catalog).length;
}
module.exports={prepare};
if(require.main===module)console.log(`${prepare(path.resolve(__dirname,'..'))} automatic interface phrases`);
