let state, catalogue, pendingFamily, familyNodes = [];
const $ = id => document.getElementById(id);
const number = value => value == null ? '暂无数据' : BigInt(value).toLocaleString('zh-CN');
const statusNames = {synced:'USB 已同步',syncing:'正在同步',disconnected:'设备未连接',searching:'寻找设备',awaiting_pet_firmware:'等待宠物固件',ambiguous:'发现多个设备',disabled:'本地预览',standby:'蓝牙待机',ble_scanning:'搜索蓝牙设备',ble_connecting:'连接蓝牙',ble_pairing:'蓝牙配对中',ble_not_found:'未发现蓝牙设备',ble_auth_failed:'蓝牙密钥不匹配',ble_needs_usb:'请先通过 USB 配置蓝牙',ble_connection_error:'蓝牙连接待重试',ble_permission_required:'请允许本机使用蓝牙',ble_dependency_missing:'蓝牙组件未安装',unavailable:'连接暂不可用',protocol_error:'同步待重试'};
function toast(text){$('toast').textContent=text;$('toast').classList.add('show');setTimeout(()=>$('toast').classList.remove('show'),2500);}
async function configure(change){
  try {const response=await fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json','X-Pet-CSRF':state.csrf},body:JSON.stringify(change)});if(!response.ok)throw Error();state=await response.json();render();toast('已保存，下一次同步会送给伙伴。');}
  catch{toast('设置未保存，请稍后再试。');}
}
function families(){
  const pokemon = new Map(catalogue.pokemon.map(p=>[p.id,p]));
  catalogue.families.forEach((family,index)=>{
    const node=document.createElement('button');node.className='family';node.dataset.family=index;
    const title=document.createElement('strong');title.textContent=pokemon.get(family.species[family.key === 'pikachu' ? 1 : 0]).name_zh+'一族';node.append(title);
    const chain=document.createElement('div');chain.className='chain';
    family.species.forEach((id,i)=>{if(i){const arrow=document.createElement('span');arrow.textContent='→';chain.append(arrow);}const image=document.createElement('img');image.src='/assets/pokemon/'+id+'.gif';image.alt=pokemon.get(id).name_zh;chain.append(image);});node.append(chain);
    const names=document.createElement('span');names.className='names';names.textContent=family.species.map(id=>pokemon.get(id).name_zh).join(' → ');node.append(names);
    node.addEventListener('click',()=>{if(state.adopted)return;pendingFamily=index;$('adopt-name').textContent=pokemon.get(family.species[0]).name_zh;$('adopt-dialog').showModal();});$('families').append(node);familyNodes.push(node);
  });
}
async function action(path,payload){
  const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-Pet-CSRF':state.csrf},body:JSON.stringify(payload)});
  if(!response.ok)throw Error('Action failed');return response.json();
}
function companion(){
  const data=state.companion;$('sessions-status').textContent=data.available?'与换台同步':'请打开换台';$('sessions-list').replaceChildren();
  for(const row of data.sessions){const button=document.createElement('button');button.className='session-button';const title=document.createElement('strong');title.textContent=row.title;const source=document.createElement('span');source.textContent=row.source+(row.openable?' · 打开会话':' · 暂不可跳转');button.append(title,source);button.disabled=!row.openable||!state.adopted;button.addEventListener('click',async()=>{button.disabled=true;try{await action('/api/open',{handle:row.handle});toast('已在来源应用打开会话。');}catch{toast('会话暂不可打开，请检查换台。');}finally{button.disabled=!row.openable;}});$('sessions-list').append(button);}
  if(!data.sessions.length){const empty=document.createElement('p');empty.className='empty';empty.textContent=data.available?'暂无未完成会话。':'换台尚未连接。';$('sessions-list').append(empty);}
  const q=data.quota;$('quota-value').textContent=q.valid?'周剩余 '+(q.remaining/10).toFixed(1)+'%':'额度未连接';$('quota-fill').style.width=q.valid?q.remaining/10+'%':'0%';$('quota-fill').classList.toggle('over',q.today!=null&&q.today<0);$('quota-mark').hidden=!q.valid||q.reference==null;if(q.reference!=null)$('quota-mark').style.left=q.reference/10+'%';
  $('quota-today').textContent=q.valid&&q.today!=null?(q.today<0?'今日超出 ':'今日参考剩余 ')+(Math.abs(q.today)/10).toFixed(1)+'%':'今日参考未连接';
  const seconds=q.valid?Math.max(0,q.reset_at-data.now):0;$('quota-reset').textContent=!q.valid?'重置时间未连接':seconds?'距重置 '+Math.floor(seconds/86400)+'天 '+String(Math.floor(seconds%86400/3600)).padStart(2,'0')+':'+String(Math.floor(seconds%3600/60)).padStart(2,'0')+':'+String(seconds%60).padStart(2,'0')+' · '+q.reset_text:'等待额度刷新';
  $('quota-detail').textContent=q.valid?(q.live?'账户额度':'离线快照，非实时')+' · 参考标记为自定节奏，非官方日限额。':'打开换台后显示账户额度和重置时间。';
}
function render(){
  document.body.classList.toggle('onboarding',!state.adopted);
  document.querySelector('h1').textContent=state.adopted?'一起成长。':'冒险从选择伙伴开始。';
  document.querySelector('.collection').hidden=state.adopted;
  if(state.adopted&&$('adopt-dialog').open)$('adopt-dialog').close();
  companion();
  $('connection').textContent=state.device.status==='synced'?(state.device.transport==='ble'?'蓝牙已同步':'USB 已同步'):statusNames[state.device.status]||'连接中';
  $('species-number').textContent='#'+String(state.species_id).padStart(3,'0');
  $('level-badge').textContent='成长 '+state.level+' / 12';
  const image=$('pet-image');if(image.dataset.id!==String(state.species_id)){image.src='/assets/pokemon/'+state.species_id+'.png';image.dataset.id=state.species_id;}image.alt=state.species.name_zh;
  image.style.width=(230+state.level*3)+'px';image.style.height=(230+state.level*3)+'px';
  const battery=state.hardware?.battery_percent;
  $('battery-status').textContent=Number.isInteger(battery)&&battery>=0&&battery<=100?'电量 '+battery+'%':'电量 --';
  $('pet-name').textContent=state.species.name_zh;
  $('pet-subtitle').textContent=state.level<5?'一点一点积攒进化能量。':state.level<9?'新的形态，新的冒险。':'一起奔向最终的成长等级。';
  $('progress-fill').style.width=state.progress+'%';
  $('next-level').textContent=state.level===12?'已达最高成长等级，继续记录每一餐。':'距离下一级还需 '+number(BigInt(state.next_threshold)-BigInt(state.pet_tokens_total))+' Token';
  $('today-label').textContent=state.source==='account'?'今日接收到账户增量':'今天吃了';
  $('today').textContent=number(state.tokens_today);$('total').textContent=number(state.pet_tokens_total);$('today-date').textContent=state.date;
  $('food-list').replaceChildren();
  if(!state.food.length){const empty=document.createElement('p');empty.className='empty';empty.textContent='今天还没有新摄入，下一次 AI 使用就是下一餐。';$('food-list').append(empty);}
  for(const food of state.food){const row=document.createElement('div');row.className='food-row';const icon=document.createElement('span');icon.className='food-icon';icon.textContent='◈';const model=document.createElement('strong');model.textContent=food.model==='account-token'?'账户 Token':food.model;const amount=document.createElement('span');amount.className='amount';amount.textContent=number(food.tokens)+' Token';row.append(icon,model,amount);$('food-list').append(row);}
  document.querySelectorAll('[data-source]').forEach(node=>node.classList.toggle('active',node.dataset.source===state.source));
  document.querySelectorAll('[data-transport]').forEach(node=>node.classList.toggle('active',node.dataset.transport===state.transport));
  $('transport-note').textContent=state.transport==='ble'?'通过低功耗蓝牙同步。首次需要 USB 配置，之后可用电池或外接电源。':state.transport==='usb'?'通过 USB 数据线同步并供电。':'优先使用 USB；USB 断开后自动尝试蓝牙。';
  $('source-note').textContent=state.source==='local'?'按本机日志完成时间记录食物。历史用量作为基线，不补喂；其他设备的使用不计入此来源。':'账户汇总可能延迟。每日摄入按本机收到增量的日期归属；切换来源先建立新基线，避免重复喂食。';
  $('account-total').textContent=number(state.account_total)+' Token';
  $('account-note').textContent=state.account_status==='ok'?'账户最新每日记录：'+(state.account_latest_date||'暂无')+'；与宠物摄入独立，不相加。':'账户统计暂不可用，本地培养继续运行。';
  $('collector-status').textContent=state.health.local==='watching'?'正在观察本地新用量':state.health.local==='no_files'?'未发现本地日志':'本地采集正在恢复';
  familyNodes.forEach((node,index)=>{node.classList.toggle('selected',index===state.family);node.setAttribute('aria-pressed',index===state.family);node.disabled=state.adopted;});
}
async function refresh(){try{const response=await fetch('/api/state');if(!response.ok)throw Error();state=await response.json();render();}catch{$('connection').textContent='主机服务未连接';}}
async function start(){catalogue=await(await fetch('/api/catalogue')).json();families();document.querySelectorAll('[data-source]').forEach(node=>node.addEventListener('click',()=>configure({source:node.dataset.source})));document.querySelectorAll('[data-transport]').forEach(node=>node.addEventListener('click',()=>configure({transport:node.dataset.transport})));$('adopt-cancel').addEventListener('click',()=>$('adopt-dialog').close());$('adopt-confirm').addEventListener('click',async()=>{const button=$('adopt-confirm');button.disabled=true;try{state=await action('/api/adopt',{family:pendingFamily});$('adopt-dialog').close();render();toast('领养成功，伙伴已锁定。');}catch{toast('领养未完成，请刷新后重试。');}finally{button.disabled=false;}});await refresh();setInterval(refresh,3000);}
start().catch(()=>{$('connection').textContent='加载失败，请刷新。';});
