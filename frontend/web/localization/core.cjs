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
module.exports={locales,textKey,matchLocale,detectLocale,detectHeaderLocale,direction,tokens};
