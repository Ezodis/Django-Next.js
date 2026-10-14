const ts=require('typescript'),path=require('node:path');
const {textKey}=require('./core.cjs');
const attributes=new Set(['title','placeholder','alt','aria-label','aria-description']);
const ignoredTags=new Set(['script','style','code','pre','svg','math','textarea']);
const decoded=new Map();
function decode(text){
 if(!text.includes('&'))return text;
 if(decoded.has(text))return decoded.get(text);
 // Let the same TypeScript JSX parser decode the full HTML entity set.
 const output=ts.transpileModule(`const value=<p>${text}</p>;`,{compilerOptions:{jsx:ts.JsxEmit.React,target:ts.ScriptTarget.ESNext}}).outputText;
 const tree=ts.createSourceFile('decoded.js',output,ts.ScriptTarget.Latest,true);
 const value=tree.statements[0].declarationList.declarations[0].initializer.arguments[2]?.text??text;
 decoded.set(text,value);return value;
}
function compile(source,filename,componentPath){
 const tree=ts.createSourceFile(filename,source,ts.ScriptTarget.Latest,true,filename.endsWith('.ts')?ts.ScriptKind.TS:ts.ScriptKind.TSX);
 const messages={};let changed=false;
 const preserve=new Set(require(path.join(process.cwd(),'package.json')).localization?.preserve??[]);
 const record=text=>{if(!/\p{L}/u.test(text)||preserve.has(text.trim()))return false;const id=textKey(text);if(messages[id]&&messages[id]!==text)throw Error('Translation key collision');messages[id]=text;return true;};
 const collect=node=>{
  if(ts.isStringLiteralLike(node))return record(node.text);
  if(ts.isConditionalExpression(node)){const left=collect(node.whenTrue),right=collect(node.whenFalse);return left||right;}
  if(ts.isParenthesizedExpression(node))return collect(node.expression);
  return false;
 };
 // Resolve authored UI bindings only. Input values, user names and backend data
 // are not translation sources; IDs and the underlying helper arguments stay intact.
 const uiName=name=>/label|placeholder|caption|heading|tooltip|buttonText|statusText|prompt/i.test(name);
 const bindings=[],calls=[],jsxCalls=[],imports=new Set();
 const scope=node=>{let parent=node.parent;while(parent&&!ts.isBlock(parent)&&!ts.isSourceFile(parent)&&!ts.isFunctionLike(parent))parent=parent.parent;return parent??tree;};
 const bind=(name,node,keys=[])=>{
  if(ts.isIdentifier(name))bindings.push({node,name:name.text,keys,scope:ts.isParameter(node)?node.parent:scope(node)});
  else if(ts.isObjectBindingPattern(name)||ts.isArrayBindingPattern(name))name.elements.forEach((element,index)=>{
   if(ts.isBindingElement(element)&&!element.dotDotDotToken)bind(element.name,node,[...keys,ts.isArrayBindingPattern(name)?String(index):(element.propertyName??element.name).getText(tree).replace(/^['"]|['"]$/g,'')]);
  });
 };
 const scan=node=>{
  if(ts.isImportDeclaration(node)&&node.importClause){
   if(node.importClause.name)imports.add(node.importClause.name.text);
   const named=node.importClause.namedBindings;
   if(named&&ts.isNamespaceImport(named))imports.add(named.name.text);
   else if(named)named.elements.forEach(item=>imports.add(item.name.text));
  }
  if(ts.isVariableDeclaration(node)||ts.isParameter(node))bind(node.name,node);
  if(ts.isCallExpression(node))calls.push(node);
  if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node))jsxCalls.push(node);
  ts.forEachChild(node,scan);
 };
 scan(tree);
 const translatorNames=new Set(['t','translate']);
 const interfaceTranslators=new Set();
 for(const item of bindings)if(ts.isVariableDeclaration(item.node)&&item.node.initializer&&ts.isCallExpression(item.node.initializer)&&item.node.initializer.expression.getText(tree)==='useInterfaceTranslator'){
  translatorNames.add(item.name);interfaceTranslators.add(item.name);
 }
 const binding=node=>bindings.filter(item=>item.name===node.text&&item.scope.pos<=node.pos&&item.scope.end>=node.end).sort((a,b)=>(a.scope.end-a.scope.pos)-(b.scope.end-b.scope.pos))[0];
 const argumentNodes=(parameter,seen)=>{
  const fn=parameter.parent,index=fn.parameters.indexOf(parameter);
  if(index===0&&ts.isCallExpression(fn.parent)&&fn.parent.arguments[0]===fn&&ts.isPropertyAccessExpression(fn.parent.expression)&&['map','flatMap','filter','find'].includes(fn.parent.expression.name.text))return elements(fn.parent.expression.expression,seen);
  const name=fn.name?.text??(ts.isVariableDeclaration(fn.parent)&&ts.isIdentifier(fn.parent.name)?fn.parent.name.text:undefined);
  return name?[...calls.filter(call=>ts.isIdentifier(call.expression)&&call.expression.text===name).map(call=>call.arguments[index]).filter(Boolean),...(index===0?jsxCalls.filter(call=>call.tagName.getText(tree)===name):[])]:[];
 };
 const unwrapped=node=>ts.isParenthesizedExpression(node)||ts.isAsExpression(node)||ts.isNonNullExpression(node)||ts.isSatisfiesExpression(node);
 const uiLookup=node=>{
  if(!ts.isElementAccessExpression(node))return false;
  let target=node.expression;while(unwrapped(target))target=target.expression;
  return ts.isObjectLiteralExpression(target)||ts.isIdentifier(target)&&uiName(target.text)||ts.isPropertyAccessExpression(target)&&uiName(target.name.text)||node.argumentExpression&&ts.isStringLiteralLike(node.argumentExpression)&&uiName(node.argumentExpression.text);
 };
 const propertyName=node=>ts.isIdentifier(node)||ts.isStringLiteralLike(node)||ts.isNumericLiteral(node)?node.text:undefined;
 const propertyValues=(node,key,seen)=>{
  if(ts.isObjectLiteralExpression(node))return node.properties.flatMap(prop=>{
   if(ts.isSpreadAssignment(prop))return resolve(prop.expression,seen).flatMap(value=>propertyValues(value,key,seen));
   if(ts.isPropertyAssignment(prop)&&(key===undefined||propertyName(prop.name)===key))return [prop.initializer];
   if(ts.isShorthandPropertyAssignment(prop)&&(key===undefined||prop.name.text===key))return [prop.name];
   return [];
  });
  if(ts.isArrayLiteralExpression(node))return key===undefined?node.elements.filter(value=>!ts.isSpreadElement(value)):node.elements[Number(key)]?[node.elements[Number(key)]]:[];
  if(ts.isJsxOpeningElement(node)||ts.isJsxSelfClosingElement(node))return node.attributes.properties.flatMap(prop=>{
   if(!ts.isJsxAttribute(prop)||propertyName(prop.name)!==key||!prop.initializer)return [];
   return ts.isJsxExpression(prop.initializer)?[prop.initializer.expression].filter(Boolean):[prop.initializer];
  });
  return [];
 };
 const bindingValues=(item,seen)=>{
  let values=[item.node.initializer,...(ts.isParameter(item.node)?argumentNodes(item.node,seen):[])].filter(Boolean);
  for(const key of item.keys)values=values.flatMap(value=>resolve(value,seen).flatMap(object=>propertyValues(object,key,seen)));
  return values;
 };
 const resolve=(node,seen=new Set())=>{
  if(!node||seen.has(node))return [];seen=new Set(seen).add(node);
  if(unwrapped(node))return resolve(node.expression,seen);
  if(ts.isConditionalExpression(node))return [...resolve(node.whenTrue,seen),...resolve(node.whenFalse,seen)];
  if(ts.isBinaryExpression(node)&&[ts.SyntaxKind.BarBarToken,ts.SyntaxKind.QuestionQuestionToken,ts.SyntaxKind.AmpersandAmpersandToken].includes(node.operatorToken.kind))return [...(node.operatorToken.kind===ts.SyntaxKind.AmpersandAmpersandToken?[]:resolve(node.left,seen)),...resolve(node.right,seen)];
  if(ts.isIdentifier(node)){
   const item=binding(node);return item?bindingValues(item,seen).flatMap(value=>resolve(value,seen)):[];
  }
  if(ts.isPropertyAccessExpression(node)||ts.isElementAccessExpression(node)){
   const key=ts.isPropertyAccessExpression(node)?node.name.text:node.argumentExpression&&propertyName(node.argumentExpression);
   // A computed identifier selects a value; its spelling is not an object key.
   const lookup=ts.isElementAccessExpression(node)&&ts.isIdentifier(node.argumentExpression)?undefined:key;
   return resolve(node.expression,seen).flatMap(object=>propertyValues(object,lookup,seen)).flatMap(value=>resolve(value,seen));
  }
  if(ts.isCallExpression(node)&&ts.isPropertyAccessExpression(node.expression)&&['filter','slice','sort','toSorted'].includes(node.expression.name.text))return resolve(node.expression.expression,seen);
  return [node];
 };
 const returns=fn=>{
  if(!fn||!ts.isArrowFunction(fn)&&!ts.isFunctionExpression(fn))return [];
  if(!ts.isBlock(fn.body))return [fn.body];
  const values=[];const visit=node=>{if(ts.isFunctionLike(node))return;if(ts.isReturnStatement(node)&&node.expression)values.push(node.expression);else ts.forEachChild(node,visit);};
  visit(fn.body);return values;
 };
 const elements=(node,seen=new Set())=>resolve(node,seen).flatMap(value=>{
  if(ts.isArrayLiteralExpression(value))return value.elements.flatMap(entry=>ts.isSpreadElement(entry)?elements(entry.expression,new Set(seen).add(value)):[entry]);
  if(ts.isCallExpression(value)&&ts.isPropertyAccessExpression(value.expression)&&['map','flatMap'].includes(value.expression.name.text))return returns(value.arguments[0]).flatMap(entry=>value.expression.name.text==='flatMap'?elements(entry,new Set(seen).add(value)):resolve(entry,new Set(seen).add(value)));
  return [];
 });
 const templatePhrases=(node,seen)=>{
  let variants=[{text:node.head.text,next:0}];
  for(const span of node.templateSpans){
   const options=[...new Set(phrases(span.expression,seen)),null];
   if(variants.length*options.length>64){const location=tree.getLineAndCharacterOfPosition(node.getStart(tree));throw Error(filename+':'+(location.line+1)+': Too many interface phrase alternatives. Use AutoText with a static source and separately translated values.');}
   variants=variants.flatMap(variant=>options.map(option=>{
    let next=variant.next;
    const part=option===null?`{v${next++}}`:option.replace(/\{v(\d+)\}/g,()=>`{v${next++}}`);
    return {text:variant.text+part+span.literal.text,next};
   }));
  }
  return [...new Set(variants.map(variant=>variant.text))];
 };
 const phrases=(node,seen=new Set())=>{
  if(!node||seen.has(node))return [];seen=new Set(seen).add(node);
  if(ts.isStringLiteralLike(node))return [node.text];
  if(ts.isTemplateExpression(node))return templatePhrases(node,seen);
  if(ts.isConditionalExpression(node))return [...phrases(node.whenTrue,seen),...phrases(node.whenFalse,seen)];
  if(unwrapped(node))return phrases(node.expression,seen);
  if(ts.isBinaryExpression(node)&&[ts.SyntaxKind.BarBarToken,ts.SyntaxKind.QuestionQuestionToken].includes(node.operatorToken.kind))return [...phrases(node.left,seen),...phrases(node.right,seen)];
  if(ts.isIdentifier(node)){
   const item=binding(node);return item&&(uiName(node.text)||item.keys.some(key=>uiName(key)))?bindingValues(item,seen).flatMap(value=>phrases(value,seen)):[];
  }
  if(ts.isPropertyAccessExpression(node)&&uiName(node.name.text)||uiLookup(node))return resolve(node,new Set([...seen].filter(value=>value!==node))).flatMap(value=>value===node?[]:phrases(value,seen));
  return [];
 };
 const candidates=node=>[...new Set(phrases(node))].filter(record);
 const catalogCalls=node=>{
  if(ts.isCallExpression(node)&&interfaceTranslators.has(node.expression.getText(tree))&&node.arguments[0]&&ts.isTemplateExpression(node.arguments[0])){
   const location=tree.getLineAndCharacterOfPosition(node.getStart(tree));
   throw Error(filename+':'+(location.line+1)+': Interpolated interface text must use AutoText with a static source and separate values.');
  }
  if((ts.isJsxSelfClosingElement(node)||ts.isJsxOpeningElement(node))&&node.tagName.getText(tree)==='AutoText'){
   const source=node.attributes.properties.find(prop=>ts.isJsxAttribute(prop)&&prop.name.getText(tree)==='source');
   if(source?.initializer&&ts.isStringLiteral(source.initializer))record(decode(source.initializer.text));
  }
  if(ts.isCallExpression(node)&&translatorNames.has(node.expression.getText(tree))&&node.arguments[0])collect(node.arguments[0]);
  ts.forEachChild(node,catalogCalls);
 };
 catalogCalls(tree);
 const factory=ts.factory;
 const textElement=(text,values)=>{
  if(!record(text))return undefined;changed=true;
  const props=[factory.createJsxAttribute(factory.createIdentifier('source'),factory.createStringLiteral(text))];
  if(values)props.push(factory.createJsxAttribute(factory.createIdentifier('values'),factory.createJsxExpression(undefined,factory.createArrayLiteralExpression(values))));
  return factory.createJsxSelfClosingElement(factory.createIdentifier('__SharedAutoText'),undefined,factory.createJsxAttributes(props));
 };
 const expression=(node,visit)=>{
  if(ts.isStringLiteralLike(node))return textElement(node.text)||node;
  if(ts.isConditionalExpression(node))return factory.updateConditionalExpression(node,node.condition,node.questionToken,expression(node.whenTrue,visit),node.colonToken,expression(node.whenFalse,visit));
  if(ts.isTemplateExpression(node)&&phrases(node).length===1){
   let text=node.head.text;const values=[];
   for(const span of node.templateSpans){text+=`{v${values.length}}`+span.literal.text;values.push(span.expression);}
   return textElement(text,values)||node;
  }
  const inferred=candidates(node);
  if(inferred.length){
   changed=true;
   return factory.createJsxSelfClosingElement(factory.createIdentifier('__SharedAutoText'),undefined,factory.createJsxAttributes([
    factory.createJsxAttribute(factory.createIdentifier('source'),factory.createJsxExpression(undefined,node)),
    factory.createJsxAttribute(factory.createIdentifier('candidates'),factory.createJsxExpression(undefined,factory.createArrayLiteralExpression(inferred.map(text=>factory.createStringLiteral(text))))),
   ]));
  }
  // Expressions may contain JSX in ternaries, logical branches and callbacks.
  // Visit those nodes without translating arbitrary application string data.
  return ts.visitNode(node,visit);
 };
 const transform=context=>{
    const localizeChild=child=>{
     if(ts.isJsxText(child)){
      const lines=child.text.split(/\r?\n/);const text=lines.length===1?child.text:lines.map((line,i)=>i===0?line.trimEnd():i===lines.length-1?line.trimStart():line.trim()).filter(Boolean).join(' ');
      return textElement(decode(text))||child;
     }
     if(ts.isJsxExpression(child)&&child.expression)return factory.updateJsxExpression(child,expression(child.expression,visit));
     return ts.visitNode(child,visit);
    };
  const visit=node=>{
   if(ts.isJsxFragment(node))return factory.updateJsxFragment(node,node.openingFragment,node.children.map(localizeChild),node.closingFragment);
   if(ts.isCallExpression(node)&&translatorNames.has(node.expression.getText(tree))&&node.arguments[0]&&ts.isStringLiteralLike(node.arguments[0]))record(node.arguments[0].text);
   if(ts.isJsxElement(node)||ts.isJsxSelfClosingElement(node)){
    const opening=ts.isJsxElement(node)?node.openingElement:node;
    const tag=opening.tagName.getText(tree);
    const skip=ignoredTags.has(tag)||opening.attributes.properties.some(p=>ts.isJsxAttribute(p)&&(p.name.getText(tree)==='data-no-translate'||p.name.getText(tree)==='contentEditable'||p.name.getText(tree)==='translate'&&p.initializer&&ts.isStringLiteral(p.initializer)&&p.initializer.text==='no'));
    if(skip)return node;
    const native=/^[a-z][a-z0-9-]*$/.test(tag);
    // Imported widgets are opaque: do not silently leave their authored UI props
    // untranslated or change a string prop into a React element.
    if(!native&&imports.has(tag.split('.')[0])&&tag!=='AutoText'&&tag!=='AutoElement'){
     for(const prop of opening.attributes.properties){
      if(!ts.isJsxAttribute(prop)||!prop.initializer||!attributes.has(prop.name.getText(tree))&&!uiName(prop.name.getText(tree)))continue;
      const value=ts.isJsxExpression(prop.initializer)?prop.initializer.expression:prop.initializer;
      if(phrases(value).some(text=>/\p{L}/u.test(text.replace(/\{v\d+\}/g,''))&&!preserve.has(text.trim()))){
       const location=tree.getLineAndCharacterOfPosition(prop.getStart(tree));
       throw Error(filename+':'+(location.line+1)+': Interface prop '+prop.name.getText(tree)+' on imported component '+tag+' must use useInterfaceTranslator() or an explicitly localized value.');
      }
     }
    }
    const keys=[],templates=[],inferredAttributes=[];
    for(const p of opening.attributes.properties)if(native&&ts.isJsxAttribute(p)&&attributes.has(p.name.getText(tree))&&p.initializer&&(ts.isStringLiteral(p.initializer)?record(decode(p.initializer.text)):ts.isJsxExpression(p.initializer)&&p.initializer.expression&&collect(p.initializer.expression)))keys.push(p.name.getText(tree));
    for(const p of opening.attributes.properties)if(native&&ts.isJsxAttribute(p)&&attributes.has(p.name.getText(tree))&&p.initializer&&ts.isJsxExpression(p.initializer)&&p.initializer.expression&&ts.isTemplateExpression(p.initializer.expression)&&phrases(p.initializer.expression).length===1){
     const template=p.initializer.expression,values=[];let text=template.head.text;
     for(const span of template.templateSpans){text+=`{v${values.length}}`+span.literal.text;values.push(span.expression);}
     if(record(text))templates.push({key:p.name.getText(tree),text,values});
    }
    for(const p of opening.attributes.properties)if(native&&ts.isJsxAttribute(p)&&attributes.has(p.name.getText(tree))&&!keys.includes(p.name.getText(tree))&&!templates.some(item=>item.key===p.name.getText(tree))&&p.initializer&&ts.isJsxExpression(p.initializer)&&p.initializer.expression){
     const found=candidates(p.initializer.expression);if(found.length)inferredAttributes.push({key:p.name.getText(tree),phrases:found});
    }
    const originalProps=opening.attributes.properties.map(p=>{
     const template=ts.isJsxAttribute(p)&&templates.find(item=>item.key===p.name.getText(tree));
     return template?factory.updateJsxAttribute(p,p.name,factory.createStringLiteral(template.text)):p;
    });
    if(tag==='option'&&ts.isJsxElement(node)&&!originalProps.some(p=>ts.isJsxAttribute(p)&&p.name.getText(tree)==='value')&&node.children.every(child=>ts.isJsxText(child))){
     originalProps.push(factory.createJsxAttribute(factory.createIdentifier('value'),factory.createStringLiteral(decode(node.children.map(child=>child.text).join('').trim()))));changed=true;
    }
    if(tag==='option'&&ts.isJsxElement(node)&&!originalProps.some(p=>ts.isJsxAttribute(p)&&p.name.getText(tree)==='value')){
     const children=node.children.filter(child=>!ts.isJsxText(child)||child.text.trim());
     if(children.length===1&&ts.isJsxExpression(children[0])&&children[0].expression&&candidates(children[0].expression).length){
      originalProps.push(factory.createJsxAttribute(factory.createIdentifier('value'),factory.createJsxExpression(undefined,children[0].expression)));changed=true;
     }
    }
    const wrapped=keys.length||templates.length||inferredAttributes.length;
    const additional=[factory.createJsxAttribute(factory.createIdentifier('as'),factory.createStringLiteral(tag)),factory.createJsxAttribute(factory.createIdentifier('translationAttributes'),factory.createJsxExpression(undefined,factory.createArrayLiteralExpression(keys.map(k=>factory.createStringLiteral(k)))))];
    if(templates.length)additional.push(factory.createJsxAttribute(factory.createIdentifier('translationTemplates'),factory.createJsxExpression(undefined,factory.createObjectLiteralExpression(templates.map(item=>factory.createPropertyAssignment(factory.createStringLiteral(item.key),factory.createObjectLiteralExpression([
     factory.createPropertyAssignment('source',factory.createStringLiteral(item.text)),factory.createPropertyAssignment('values',factory.createArrayLiteralExpression(item.values)),
    ])))))));
    if(inferredAttributes.length)additional.push(factory.createJsxAttribute(factory.createIdentifier('translationCandidates'),factory.createJsxExpression(undefined,factory.createObjectLiteralExpression(inferredAttributes.map(item=>factory.createPropertyAssignment(factory.createStringLiteral(item.key),factory.createArrayLiteralExpression(item.phrases.map(text=>factory.createStringLiteral(text)))))))));
    const props=factory.createJsxAttributes(wrapped?[...originalProps,...additional]:originalProps);
    const name=wrapped?factory.createIdentifier('__SharedAutoElement'):opening.tagName;
    if(wrapped)changed=true;
    if(ts.isJsxSelfClosingElement(node))return factory.updateJsxSelfClosingElement(node,name,node.typeArguments,props);
    const children=node.children.map(localizeChild);
    return factory.updateJsxElement(node,factory.updateJsxOpeningElement(opening,name,opening.typeArguments,props),children,factory.updateJsxClosingElement(node.closingElement,name));
   }
   return ts.visitEachChild(node,visit,context);
  };
  return node=>ts.visitNode(node,visit);
 };
 const result=ts.transform(tree,[transform]);let output=tree;
 if(changed){
  const reference=componentPath??path.join(__dirname,'client');
  const declaration=factory.createImportDeclaration(undefined,factory.createImportClause(false,undefined,factory.createNamedImports(['AutoText','AutoElement'].map(name=>factory.createImportSpecifier(false,factory.createIdentifier(name),factory.createIdentifier('__Shared'+name))))),factory.createStringLiteral(reference.replaceAll('\\','/')));
  const statements=[...result.transformed[0].statements];let index=0;
  while(index<statements.length&&ts.isExpressionStatement(statements[index])&&ts.isStringLiteral(statements[index].expression))index++;
  statements.splice(index,0,declaration);output=factory.updateSourceFile(result.transformed[0],statements);
 }
 const code=changed?ts.createPrinter({newLine:ts.NewLineKind.LineFeed}).printFile(output):source;
 result.dispose();return {code,messages};
}
module.exports={compile};
