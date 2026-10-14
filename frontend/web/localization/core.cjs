const locales = ['en','es','de','fr','ru','ar','pt','it','nl','zh-CN','zh-TW','ja','ko','hi','uk','pl','tr','sv','da','nb','fi','cs','el','ro','hu','he','th','vi','id','ms','fil','bn','ur','fa','sw','ta','te','mr','gu','pa','kn','ml','ne','si','km','lo','my','am','zu','af','ca','eu','gl','is','et','lv','lt','sk','sl','hr','sr','bg','bs','mk','sq','hy','ka','az','kk','uz','mn'];
function textKey(text){let hash=2166136261;for(let i=0;i<text.length;i++)hash=Math.imul(hash^text.charCodeAt(i),16777619);return 'm'+(hash>>>0).toString(16);}
function matchLocale(value){try{const tag=new Intl.Locale(String(value).replaceAll('_','-'));if(tag.language==='zh')return tag.script==='Hant'||['TW','HK','MO'].includes(tag.region)?'zh-TW':'zh-CN';const language=tag.language==='no'?'nb':tag.language==='tl'?'fil':tag.language;return locales.includes(language)?language:undefined;}catch{return undefined;}}
function detectLocale(values){for(const value of values??[]){const matched=matchLocale(value);if(matched)return matched;}return 'en';}
function detectHeaderLocale(value){
 const values=String(value??'').split(',').map((entry,index)=>{
  const [tag,...parameters]=entry.trim().split(';');
  const quality=parameters.find(part=>part.trim().startsWith('q='));
  const q=quality?Number(quality.trim().slice(2)):1;
  return {tag,q,index};
 }).filter(item=>Number.isFinite(item.q)&&item.q>0&&item.q<=1).sort((a,b)=>b.q-a.q||a.index-b.index);
 return detectLocale(values.map(item=>item.tag));
}
function direction(locale){return ['ar','he','fa','ur'].includes(locale)?'rtl':'ltr';}
function tokens(text){return (text.match(/\{v\d+\}/g)||[]).sort().join(',');}
function matchAuthoredPhrase(value,candidates){
 if(typeof value!=='string')return undefined;
 const exact=candidates?.find(source=>source===value);
 if(exact!==undefined)return {source:exact};
 // Prefer authored alternatives over broad templates, regardless of list order.
 const ordered=[...(candidates??[])].sort((a,b)=>tokens(a).split(',').filter(Boolean).length-tokens(b).split(',').filter(Boolean).length||b.replace(/\{v\d+\}/g,'').length-a.replace(/\{v\d+\}/g,'').length);
 for(const source of ordered){
  const indices=[];
  const pattern=source.split(/(\{v\d+\})/g).map(part=>{
   const token=/^\{v(\d+)\}$/.exec(part);
   if(token){indices.push(Number(token[1]));return '(.*?)';}
   return part.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  }).join('');
  if(!indices.length)continue;
  const matched=new RegExp('^'+pattern+'$','s').exec(value);
  if(matched){const values=[];indices.forEach((index,position)=>values[index]=matched[position+1]);return {source,values};}
 }
 return undefined;
}
module.exports={matchAuthoredPhrase,locales,textKey,matchLocale,detectLocale,detectHeaderLocale,direction,tokens};
