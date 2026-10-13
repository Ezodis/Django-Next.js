const {test}=require('node:test'),assert=require('node:assert/strict');
const {compile}=require('./compiler.cjs');
const {detectLocale,matchLocale,direction,textKey}=require('./core.cjs');
const {createService}=require('./service.cjs');

test('translator aliases register new copy and reject unsafe dynamic templates',()=>{
 const result=compile(`const localize=useInterfaceTranslator();const caption=localize('New checkout caption');`,'page.tsx');
 assert.equal(result.messages[textKey('New checkout caption')],'New checkout caption');
 assert.throws(()=>compile('const localize=useInterfaceTranslator();localize(`Hello ${person.name}`);','page.tsx'),/static source and separate values/);
});

test('direct production builds invoke the coverage gate',()=>{
 const ts=require('typescript'),Module=require('node:module');
 const file=path.join(__dirname,'../next.config.shared.ts'),compiledModule=new Module(file,module);
 compiledModule.filename=file;compiledModule.paths=Module._nodeModulePaths(__dirname);
 const original=compiledModule.require.bind(compiledModule);let called=false;
 compiledModule.require=id=>id==='./localization/prepare.cjs'?{verify:()=>{called=true;throw Error('Incomplete production dictionary');},prepare:()=>{throw Error('Production must not silently prepare source');}}:original(id);
 compiledModule._compile(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText,file);
 const before=process.env.NODE_ENV;
 try{process.env.NODE_ENV='production';assert.throws(()=>compiledModule.exports.withSharedDevConfig({}),/Incomplete production dictionary/);assert.equal(called,true);}
 finally{if(before===undefined)delete process.env.NODE_ENV;else process.env.NODE_ENV=before;}
});

test('helper option placeholders are discovered without translating input values',()=>{
 const result=compile(`const field=(options:{placeholder:string},value:string)=><input placeholder={options.placeholder} value={value}/>; const page=field({placeholder:'Your delivery address'},user.address);`,'page.tsx');
 assert.equal(result.messages[textKey('Your delivery address')],'Your delivery address');
 assert.match(result.code,/translationCandidates/);assert.match(result.code,/value=\{value\}/);
 const defaults=compile(`const field=(label='Recipient',options={placeholder:'Additional information'})=><label>{label}<input placeholder={options.placeholder}/></label>;`,'page.tsx');
 for(const phrase of ['Recipient','Additional information'])assert.equal(defaults.messages[textKey(phrase)],phrase);
});

test('coverage verification rejects undiscovered UI and incomplete locales without modifying files',()=>{
 const {prepare,verify}=require('./prepare.cjs');
 const {locales}=require('./core.cjs');
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'translation-coverage-'));
 try{
  fs.mkdirSync(path.join(root,'app'));fs.mkdirSync(path.join(root,'messages'));
  fs.writeFileSync(path.join(root,'package.json'),'{}');
  fs.writeFileSync(path.join(root,'app/page.tsx'),'<p>New interface heading</p>');
  const manifest=path.join(root,'messages/automatic-source.json');fs.writeFileSync(manifest,'{}');
  assert.throws(()=>verify(root),/1 unregistered phrases/);assert.equal(fs.readFileSync(manifest,'utf8'),'{}');
  prepare(root);const source=JSON.parse(fs.readFileSync(manifest,'utf8'));
  fs.mkdirSync(path.join(root,'messages/automatic'));
  for(const locale of locales)fs.writeFileSync(path.join(root,'messages/automatic',locale+'.json'),JSON.stringify(Object.fromEntries(Object.entries(source).map(([id,text])=>[id,{source:text,translation:'Localized heading'}]))));
  assert.equal(verify(root),1);
  fs.writeFileSync(path.join(root,'messages/automatic/es.json'),'{}');
  const before=fs.readFileSync(manifest,'utf8');assert.throws(()=>verify(root),/es: 1/);assert.equal(fs.readFileSync(manifest,'utf8'),before);
 }finally{assert.ok(path.resolve(root).startsWith(path.resolve(os.tmpdir())+path.sep));fs.rmSync(root,{recursive:true,force:true});}
});

test('new helper labels and computed captions are discovered without changing identifiers or private data',()=>{
 const result=compile(`const field=(label:string,value:string)=><label htmlFor={label}>{label}<input value={value}/></label>; const searchLabel=count?\`Show \${count} books\`:'Search books'; export default()=> <>{field('New delivery label',person.name)}<button>{searchLabel}</button><p>{personName}</p></>; const personName='Private Person';`,'page.tsx');
 for(const phrase of ['New delivery label','Show {v0} books','Search books'])assert.equal(result.messages[textKey(phrase)],phrase);
 assert.ok(!Object.values(result.messages).includes('Private Person'));
 assert.match(result.code,/htmlFor=\{label\}/);assert.match(result.code,/value=\{value\}/);assert.match(result.code,/candidates=/);
});

test('inferred phrases match only authored patterns and preserve interpolation values',()=>{
 const {matchAuthoredPhrase}=require('./core.cjs');
 assert.deepEqual(matchAuthoredPhrase('Show 42 books',['Show {v0} books']),{source:'Show {v0} books',values:['42']});
 assert.equal(matchAuthoredPhrase('Private Person',['Search books']),undefined);
 assert.deepEqual(matchAuthoredPhrase('Open [item] 5?',['Open [item] {v0}?']),{source:'Open [item] {v0}?',values:['5']});
});

test('attribute templates localize their captions without cataloging private values',()=>{
 const result=compile('<button aria-label={`Copies of ${book.title}`} title={`View ${book.title}`}>{book.title}</button>','page.tsx');
 assert.deepEqual(Object.values(result.messages),['Copies of {v0}','View {v0}']);
 assert.match(result.code,/translationTemplates/);assert.match(result.code,/values: \[book.title\]/);
 assert.match(result.code,/\{book.title\}/);
});

test('fragment-based labels translate entire singular and plural phrases',()=>{
 const result=compile("const label=count===1?<>{`Show ${count} book`}</>:<>{`Show ${count} books`}</>;",'page.tsx');
 for(const phrase of ['Show {v0} book','Show {v0} books'])assert.equal(result.messages[textKey(phrase)],phrase);
});

test('conditional accessibility labels translate without changing option values',()=>{
 const result=compile(`<button aria-label={open ? 'Close book' : 'Open book'} title={saved ? 'In cart' : 'Add to cart'} onClick={save}>Save</button>`,'page.tsx');
 for(const phrase of ['Close book','Open book','In cart','Add to cart'])assert.equal(result.messages[textKey(phrase)],phrase);
 assert.match(result.code,/translationAttributes/);assert.match(result.code,/onClick=\{save\}/);
});

test('conditional, logical and mapped JSX translate every nested interface phrase',()=>{
 const result=compile(`export default () => <div>{failed ? <p>Try fewer filters.</p> : <section><h2>Address your parcel.</h2>{ready && <button>Continue</button>}{items.map(item => <span title="Open item">{item.name} Details</span>)}</section>}</div>`,'page.tsx');
 for(const phrase of ['Try fewer filters.','Address your parcel.','Continue','Open item',' Details'])assert.equal(result.messages[textKey(phrase)],phrase);
 assert.match(result.code,/\{item.name\}/);
 assert.ok(!Object.values(result.messages).includes('item.name'));
});

test('server catalog refreshes when development discovers new interface phrases',async()=>{
 const fs=require('node:fs'),path=require('node:path'),ts=require('typescript'),Module=require('node:module');
 let manifest=JSON.stringify({[textKey('First')]: 'First'}),calls=0;
 const file=path.join(__dirname,'server.ts'),compiledModule=new Module(file,module);
 compiledModule.filename=file;compiledModule.paths=Module._nodeModulePaths(__dirname);
 const original=compiledModule.require.bind(compiledModule);
 compiledModule.require=id=>id==='server-only'?{}:id==='next/headers'?{}:id==='next/cache'?{unstable_cache:fn=>fn}:id==='node:fs'?{readFileSync:()=>manifest}:id==='./catalog.cjs'?{prepareCatalog:async(_root,_locale,source)=>{calls++;return source;}}:original(id);
 compiledModule._compile(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText,file);
 const {getInterfaceCatalog}=compiledModule.exports;
 const first=getInterfaceCatalog('es');assert.equal(getInterfaceCatalog('es'),first);await first;
 manifest=JSON.stringify({[textKey('First')]:'First',[textKey('New checkout label')]:'New checkout label'});
 const updated=await getInterfaceCatalog('es');
 assert.equal(updated[textKey('New checkout label')],'New checkout label');assert.equal(calls,2);
});
test('interpolation-only phrases preserve values without requesting translation',async()=>{
 const phrase='{v0}{v1}',source={[textKey(phrase)]:phrase};
 const service=createService({source,fetch:async()=>{throw Error('Must not contact provider');}});
 assert.equal((await service({language:'sr',ids:Object.keys(source)}))[textKey(phrase)],phrase);
});
test('device languages normalize scripts and aliases with a safe fallback',()=>{
 assert.equal(detectLocale(['ru-RU','en']),'ru');assert.equal(detectLocale(['de-DE']),'de');
 assert.equal(detectLocale(['ar-SA']),'ar');assert.equal(direction('ar'),'rtl');
 assert.equal(matchLocale('zh-Hant-HK'),'zh-TW');assert.equal(matchLocale('no-NO'),'nb');
 assert.equal(detectLocale(['invalid language','fr-FR']),'fr');assert.equal(matchLocale('../../secret'),undefined);
});
test('new JSX phrases and accessibility labels compile without altering private expressions or handlers',()=>{
 const source="'use client'; export default function Page(){return <section><button onClick={save} aria-label=\"Save changes\">Save</button><p>{person.name}</p><p>{enabled ? 'Ready' : 'Waiting'}</p><div translate=\"no\">Private literal</div><code>Raw code</code></section>}";
 const result=compile(source,'page.tsx');
 for(const text of ['Save changes','Save','Ready','Waiting'])assert.equal(result.messages[textKey(text)],text);
 assert.ok(!Object.values(result.messages).includes('Private literal'));
 assert.ok(!Object.values(result.messages).includes('Raw code'));
 assert.match(result.code,/onClick=\{save\}/);assert.match(result.code,/\{person.name\}/);
 assert.ok(result.code.indexOf('use client')<result.code.indexOf('import'));
 assert.match(result.code,/__SharedAutoElement/);
});
test('dynamic template values remain separate from authored source phrases',()=>{
 const result=compile('export default ()=> <p>{`Hello ${person.name}, you have ${count} messages`}</p>','page.tsx');
 assert.deepEqual(Object.values(result.messages),['Hello {v0}, you have {v1} messages']);
 assert.match(result.code,/values=\{\[person.name, count\]\}/);
});
test('JSX entities are decoded once and remain valid text',()=>{
 const result=compile('<p>Privacy &amp; Terms &copy;</p>','page.tsx');
 assert.deepEqual(Object.values(result.messages),['Privacy & Terms ©']);
});
test('select option values remain their original values while labels translate',()=>{
 const result=compile('<select><option>Weekly</option><option value="month">Monthly</option></select>','page.tsx');
 assert.match(result.code,/value="Weekly"/);assert.match(result.code,/value="month"/);
});
test('runtime translation batches static phrases, deduplicates requests and caches results',async()=>{
 const source=Object.fromEntries(['Welcome','Save'].map(text=>[textKey(text),text]));let calls=0;
 const service=createService({source,fetch:async url=>{calls++;assert.deepEqual(new URL(url).searchParams.getAll('q'),['Welcome','Save']);return {ok:true,json:async()=>['Willkommen','Speichern']};}});
 const request={language:'de-DE',ids:Object.keys(source)};
 const [first,second]=await Promise.all([service(request),service(request)]);
 assert.deepEqual(first,second);assert.equal(first[textKey('Save')],'Speichern');
 await service(request);assert.equal(calls,1);
 await assert.rejects(service({language:'de',ids:[textKey('A private message')]}));
 assert.equal(calls,1);
});
test('failed or malformed translations are not cached and interpolation tokens survive',async()=>{
 const phrase='Hello {v0}',source={[textKey(phrase)]:phrase};let calls=0;
 const service=createService({source,fetch:async()=>{calls++;if(calls===1)return {ok:false};return {ok:true,json:async()=>['Hallo {v0}']};}});
 await assert.rejects(service({language:'de',ids:Object.keys(source)}));
 const translated=await service({language:'de',ids:Object.keys(source)});
 assert.equal(translated[textKey(phrase)],'Hallo {v0}');assert.equal(calls,2);
});
test('machine-translated placeholder names are repaired without sending interpolated values',async()=>{
 const phrase='Hello {v0}',source={[textKey(phrase)]:phrase};let calls=0;
 const service=createService({source,fetch:async url=>{calls++;const phrases=new URL(url).searchParams.getAll('q');assert.ok(!phrases.includes('Private Person'));return {ok:true,json:async()=>[calls===1?'Hallo übersetzterName':'Hallo']};}});
 const translated=await service({language:'de',ids:Object.keys(source)});
 assert.equal(translated[textKey(phrase)],'Hallo {v0}');assert.equal(calls,2);
});
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {readCatalog,prepareCatalog}=require('./catalog.cjs');
const {detectHeaderLocale}=require('./core.cjs');
test('request language respects quality, aliases and excluded languages',()=>{
 assert.equal(detectHeaderLocale('en;q=0,de-DE;q=0.8,ru;q=1'),'ru');
 assert.equal(detectHeaderLocale('xx,ar-SA;q=0.4'),'ar');
 assert.equal(detectHeaderLocale('en;q=0,xx;q=1'),'en');
});
test('complete catalogs reuse translations and generate only new authored text',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'interface-catalog-'));
 try {
  const first='Hello {v0}',second='Welcome';let calls=0;
  const source={[textKey(first)]:first};
  const translate=async({ids})=>{calls++;return Object.fromEntries(ids.map(id=>[id,id===textKey(first)?'Hallo {v0}':'Willkommen']));};
  const catalog=await prepareCatalog(root,'de',source,{translate});
  assert.equal(catalog[textKey(first)],'Hallo {v0}');
  await prepareCatalog(root,'de',source,{translate});assert.equal(calls,1);
  source[textKey(second)]=second;
  await prepareCatalog(root,'de',source,{translate});assert.equal(calls,2);
  assert.equal(Object.keys(readCatalog(root,'de',source)).length,2);
 } finally {fs.rmSync(root,{recursive:true,force:true});}
});
test('failed generation cannot publish a partial or stale catalog',async()=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'interface-catalog-'));
 try {
  const source={[textKey('Hello')]: 'Hello'};
  const file=path.join(root,'messages','automatic','de.json');
  await assert.rejects(prepareCatalog(root,'de',source,{translate:async()=>({})}),/Incomplete/);
  assert.equal(fs.existsSync(file),false);
  fs.mkdirSync(path.dirname(file),{recursive:true});
  fs.writeFileSync(file,JSON.stringify({[textKey('Hello')]:{source:'Different',translation:'Hallo'}}));
  assert.deepEqual(readCatalog(root,'de',source),{});
 } finally {fs.rmSync(root,{recursive:true,force:true});}
});
test('the first server render includes localized text and interpolation values',()=>{
 const ts=require('typescript'),React=require('react'),{renderToString}=require('react-dom/server');
 const Module=require('node:module');
 const file=path.join(__dirname,'client.tsx');
 const compiled=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{jsx:ts.JsxEmit.ReactJSX,module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText;
 const compiledModule=new Module(file,module);compiledModule.filename=file;compiledModule.paths=Module._nodeModulePaths(__dirname);compiledModule._compile(compiled,file);
 const {AutomaticTranslationProvider,AutoText}=compiledModule.exports;
 const phrase='Hello {v0}';
 const html=renderToString(React.createElement(AutomaticTranslationProvider,{initial:{language:'de',catalog:{[textKey(phrase)]:'Hallo {v0}'}}},React.createElement(AutoText,{source:phrase,values:['Private Person']})));
 assert.ok(html.includes('Hallo'));assert.ok(html.includes('Private Person'));assert.ok(!html.includes('Hello'));
 const helper='Show {v0} books';
 const inferred=renderToString(React.createElement(AutomaticTranslationProvider,{initial:{language:'de',catalog:{[textKey(helper)]:'{v0} Bücher anzeigen'}}},React.createElement(AutoText,{source:'Show 42 books',candidates:[helper]})));
 assert.ok(inferred.includes('Bücher anzeigen'));assert.ok(inferred.includes('42'));assert.ok(!inferred.includes('Show'));
});
test('legacy manual preferences migrate before paint without reload loops',()=>{
 const ts=require('typescript'),Module=require('node:module'),vm=require('node:vm');
 const file=path.join(__dirname,'server.ts'),compiledModule=new Module(file,module);
 compiledModule.filename=file;compiledModule.paths=Module._nodeModulePaths(__dirname);
 const original=compiledModule.require.bind(compiledModule);
 compiledModule.require=id=>id==='server-only'?{}:id==='next/headers'?{}:id==='next/cache'?{unstable_cache:fn=>fn}:original(id);
 compiledModule._compile(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,esModuleInterop:true}}).outputText,file);
 const script=compiledModule.exports.manualLanguageBootstrap('language','UI_LANGUAGE');
 let cookie='',reloads=0;
 const document={get cookie(){return cookie;},set cookie(value){cookie=value.split(';')[0];}};
 const context={document,localStorage:{getItem:()=> 'de'},location:{reload:()=>reloads++}};
 vm.runInNewContext(script,context);assert.equal(cookie,'UI_LANGUAGE=de');assert.equal(reloads,1);
 vm.runInNewContext(script,context);assert.equal(reloads,1);
 vm.runInNewContext(script,{...context,document:{get cookie(){return '';},set cookie(_){} }});assert.equal(reloads,1);
 const automatic=compiledModule.exports.manualLanguageBootstrap('language','UI_LANGUAGE','auto');
 cookie='UI_LANGUAGE=de';context.localStorage.getItem=()=> 'auto';vm.runInNewContext(automatic,context);assert.equal(cookie,'UI_LANGUAGE=');assert.equal(reloads,2);
});
