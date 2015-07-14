Db = require 'db'
Dom = require 'dom'
Form = require 'form'
Icon = require 'icon'
Modal = require 'modal'
Obs = require 'obs'
Plugin = require 'plugin'
Page = require 'page'
Server = require 'server'
Ui = require 'ui'
{tr} = require 'i18n'
Social = require 'social'
Time = require 'time'
Event = require 'event'


exports.render = ->
	log "Plugin.api() = "+Plugin.api()
	if Plugin.api() <= 1
		Dom.text "Reload the happening"
		return
	req0 = Page.state.get(0)
	if req0 is 'new'
		renderEditOrNew()
		return
	if req0 is 'balances'
		renderBalances()
		return
	if +req0 and Page.state.get(1) is 'edit'
		renderEditOrNew +req0
		return
	if +req0
		renderView +req0
		return

	Event.markRead(["transaction"])
	# Balances
	Ui.list !->
		Dom.div !->
			balance = (Db.shared.get("balances", Plugin.userId())||0)
			Dom.style Box: 'horizontal'
			Dom.div !->
				Dom.text tr("Show all balances")
				Dom.style 
					Flex: true
					color: Plugin.colors().highlight
					marginTop: '1px'
			Dom.div !->
				Dom.text "Yours:"
				Dom.style
					textAlign: 'right'
					margin: '1px 10px 0 0'
			Dom.div !->
				Dom.style
					fontWeight: "bold"
					fontSize: '120%'
					textAlign: 'right'
				stylePositiveNegative(balance)
				Dom.text formatMoney(balance)
		Dom.onTap !->
			Page.nav ['balances']

	settleO = Db.shared.ref('settle')
	if settleO.isHash()
		renderSettlePane(settleO)

	Ui.list !->
		# Add new transaction
		Ui.item !->
			Dom.text "+ Add transaction"
			Dom.style
				color: Plugin.colors().highlight
			Dom.onTap !->
				Page.nav ['new']
		# Latest transactions
		if Db.shared.count("transactions").get() isnt 0
			Db.shared.iterate 'transactions', (tx) !->
				Ui.item !->
					Dom.div !->
						Dom.style Box: 'horizontal', width: '100%'
						Dom.div !->
							Dom.style Flex: true
							created = tx.get("created")
							updated = tx.get("updated")
							eventTime = updated ? created
							#log "eventTime=", eventTime, Event.isNew(eventTime)
							Event.styleNew(eventTime)
							if tx.get('type') is 'settle'
								Dom.text tr("Settle payment")
							else
								Dom.text capitalizeFirst(tx.get('text'))
							Dom.style fontWeight: "bold"
							Dom.div !->
								Dom.style fontSize: '80%', fontWeight: "normal"
								byIds = (id for id of tx.get('by'))
								forIds = (id for id of tx.get('for'))
								forCount = tx.count('for').get()
								target = ""
								if tx.get('type') is 'settle'
									Dom.text tr("%1 by %2 for %3.", formatMoney(tx.get('total')), formatGroup(byIds, false), formatGroup(forIds, false))
								else
									Dom.text tr("%1 by %2 for %3 person#{if forCount>1 then "s" else ""}.", formatMoney(tx.get('total')), formatGroup(byIds, false), forCount)								
								if created?
									Dom.br()
									Time.deltaText created
									if updated?
										Dom.text tr(", edited ")
										Time.deltaText updated
									Dom.text "."
						# Your share
						Dom.div !->
							share = calculateShare(tx, Plugin.userId())
							stylePositiveNegative(share)
							Dom.text formatMoney(share)
							if share is 0
								Dom.style color: '#999999'

					Dom.onTap !->
						Page.nav [tx.key()]
			, (tx) -> -tx.key()
		else
			Ui.emptyText tr("Create a new transaction with the button below.")

renderBalances = !->
	Page.setTitle "All balances"
	Ui.list !->
		Dom.h2 tr("Balances")
		Plugin.users.iterate (user) !->
			Ui.item !->
				balance = (Db.shared.get("balances", user.key()) ||0)
				stylePositiveNegative(balance)
				Ui.avatar Plugin.userAvatar(user.key()), 
					onTap: (!-> Plugin.userInfo(user.key()))
					style: marginRight: "10px"
				Dom.div !->
					Dom.style Flex: true
					Dom.div formatName(user.key(), true)
				Dom.div !->
					 Dom.text formatMoney(balance)
		, (user) -> 
			# Sort users with zero balance to the bottom
			number = Db.shared.get("balances", user.key())||0
			if number is 0
				return 9007199254740991
			else
				return number
		
		settleO = Db.shared.ref('settle') 
		if !settleO.isHash()
			total = Obs.create 0
			Db.shared.iterate "balances", (user) !->
				value = user.get()
				total.modify((v) -> (v||0)+Math.abs(value))
				Obs.onClean !->
					total.modify((v) -> (v||0)-Math.abs(value))
			if total.get() isnt 0
				if Plugin.userIsAdmin()
					Dom.div !->
						Dom.style textAlign: 'right'
						Ui.button tr("Initiate settle"), !->
							require('modal').confirm tr("Initiate settle?"), tr("People with negatives balance are asked to pay up. People with a positive balances should confirm their payments."), !->
								Server.call 'settleStart'
				else
					Dom.div !->
						Dom.style
							textAlign: 'center'
							margin: '4px 0'
							fontSize: '80%'
							color: '#888'
							fontStyle: 'italic'
						Dom.text tr("Want to settle balances? Ask a group admin to initiate settle mode!")

# Render a transaction
renderView = (txId) !->
	transaction = Db.shared.ref("transactions", txId)
	# Check for incorrect transaction ids
	if !transaction.isHash()
		Ui.emptyText tr("No such transaction")
		return
	Page.setTitle "Viewing transaction"
	# Set the page actions
	Page.setActions
		icon: 'edit'
		label: "Edit transaction"
		action: !->
			Page.nav [transaction.key(), 'edit']
	# Render paid by items
	Dom.section !->
		Dom.h2 tr("Description")
		if Db.shared.get("transactions", txId, "type") is 'settle'
			Dom.text tr("Settle payment generated by the plugin to equal balances.")
		else
			Dom.text transaction.get("text")
		Dom.div !->
			Dom.style fontSize: '80%'
			created = Db.shared.get("transactions", txId, "created")
			updated = Db.shared.get("transactions", txId, "updated")
			if created?
				Dom.br()
				Dom.text "Created "
				Time.deltaText created
				if updated?
					Dom.text tr(", edited ")
					Time.deltaText updated
				Dom.text "."
	Ui.list !->
		Dom.h2 tr("Paid by")
		renderBalanceSplitSection(transaction.get("total"), transaction.ref("by"))
	# Render paid for items
	Ui.list !->
		Dom.h2 tr("Paid for")
		renderBalanceSplitSection(transaction.get("total"), transaction.ref("for"))
	# Comments
	Social.renderComments(txId)

renderBalanceSplitSection = (total, path) !->
	remainder = Obs.create(total)
	usersLeft = Obs.create(path.count().get())
	Obs.observe !->
		path.iterate (user) !->
			amount = user.get()
			number = 0
			suffix = undefined
			if amount is true
				number = Math.round((remainder.get()*100.0)/usersLeft.get())/100.0
			else if (amount+"").substr(-1) is "%"
				amount = amount+""
				percent = +(amount.substr(0, amount.length-1))
				number = Math.round(percent*total)/100.0
				remainder.modify((v) -> v-number)
				usersLeft.modify (v) -> v-1
				suffix = percent+"%"
				Obs.onClean !->
					usersLeft.incr()
					remainder.modify((v) -> v+number)
			else
				number = +amount
				remainder.modify (v) -> v-number
				usersLeft.modify (v) -> v-1
				suffix = "fixed"
				Obs.onClean !->
					usersLeft.incr()
					remainder.modify((v) -> v+number)
			# TODO: Assign possibly remaining part of the total to someone
			Ui.item !->
				Ui.avatar Plugin.userAvatar(user.key()), 
					onTap: (!-> Plugin.userInfo(user.key()))
					style: marginRight: "10px"
				Dom.div !->
					Dom.style Flex: true
					Dom.div formatName(user.key(), true)
				Dom.div !->
					 Dom.text formatMoney(number)
					 if suffix isnt undefined
					 	Dom.text " ("+suffix+")"
		, (amount) ->
			# Sort static on top, then percentage, then remainder
			return getSortValue(amount.get())
			
# Render a transaction edit page
renderEditOrNew = (editId) !->
	if editId
		edit = Db.shared.ref('transactions', editId)
		if !edit.isHash()
			Ui.emptyText tr("No such transaction")
			return
			
		Page.setTitle "Editing transaction"
	else
		Page.setTitle "Creating new transaction"

	# Check if there is an ongoing settle
	if Db.shared.isHash('settle')
		Dom.div !->
			Dom.style
				margin: '0 0 8px'
				background: '#888'
				color: '#fff'
				fontSize: '80%'
				padding: '4px'
				fontStyle: 'italic'
			Dom.text tr("There is an ongoing settle. ")
			if editId
				Dom.text tr("Changes in transactions will not be included.")
			else
				Dom.text tr("New transactions will not be included.")
	# Current form total
	totalO = Obs.create 0	
	byO = undefined

	# Description and amount input
	Dom.section !->
		if Db.shared.peek("transactions", editId)?
			Dom.h2 "Transaction details (editing)"
		else
			Dom.h2 "New transaction details"
		Dom.div !->
			Dom.style Box: 'middle', marginBottom: '-10px'
			Dom.div !->
				Dom.style Flex: true
				Dom.text tr("Description:")
		Dom.div !->
			Dom.style Box: 'top'
			Dom.div !->
				Dom.style Flex: true
				defaultValue = undefined
				if Db.shared.get("transactions", editId, "type") is 'settle'
					defaultValue = "Settle payment generated by the plugin to equal balances."
				else if edit
					defaultValue = edit.get('text')
				Form.input
					name: 'text'
					value: defaultValue
					text: ""
		Dom.div !->
			Dom.style fontSize: '80%'
			created = Db.shared.get("transactions", editId, "created")
			updated = Db.shared.get("transactions", editId, "updated")
			if created?
				Dom.text "Created "
				Time.deltaText created
				if updated?
					Dom.text tr(", last edited ")
					Time.deltaText updated
				Dom.text "."
			# No amount entered	
			Form.condition (values) ->
				if (not (values.text?)) or values.text.length < 1
					return tr("Enter a description")
	multiplePaidBy = Obs.create(false)
	totalSave = undefined
	bySave = undefined
	Ui.list !->
		Dom.h2 tr("Paid by")
		log 'full list refresh'
		byO = Obs.create {}
		if edit
			byO.set edit.get('by')
		userCount = 0
		byO.iterate (user) !->
			userCount++
			Obs.onClean !-> userCount--
		if userCount > 1
			multiplePaidBy.set(true)
		if userCount == 0
			byO.set Plugin.userId(), 0

		Obs.observe !->
			total = 0
			byO.iterate (user) !->
				total += user.get()
			totalO.set total
		[handleChange] = Form.makeInput
			name: 'by'
			value: byO.peek()
		Obs.observe !->
			handleChange byO.get()
		Obs.observe !->
			if not multiplePaidBy.get()
				Ui.item !->
					userKey = ""
					byO.iterate (user) !->
						userKey = user.key()
					Ui.avatar Plugin.userAvatar(userKey), 
						onTap: (!-> Plugin.userInfo(userKey))
						style: marginRight: "10px"
					Dom.div !->
						Dom.style Flex: true
						Dom.div formatName(userKey, true)
					Dom.div !->
						currency = "€"
						if Db.shared.get("currency")
							currency = Db.shared.get("currency")
						Dom.text currency
						Dom.style 
							margin: '-3px 5px 0 0'
							fontSize: '21px'
					Dom.div !->
						Dom.style width: '80px', margin: '-20px 0 -20px 0'
						Form.input
							name: 'total'
							type: 'number'
							text: '0.-'
							value: edit.peek('total') if edit
							onChange: (value) ->
								log 'user write', +value, " byO="+JSON.stringify(byO)
								bySave = byO.peek()
								oldValue = byO.peek(userKey)
								totalSave = totalO.peek()
								byO.set userKey, +value
								totalO.modify((v) -> v-oldValue+(+value))
								return
			else
				# Setup temporary data
				if totalSave isnt undefined
					temp = totalSave
					totalSave = undefined
					totalO.set temp
				if bySave isnt undefined
					temp = bySave
					bySave = undefined
					byO.set temp
				# Set form input
				Obs.observe !->
					log "users reresh"
					Dom.div !->
						Dom.style margin: '5px -5px 0 -5px'
						Plugin.users.iterate (user) !->
							amount = byO.get(user.key())
							number = 0
							suffix = undefined
							if amount
								number = +amount
							# TODO: Assign possibly remaining part of the total to someone

							Dom.div !-> # Aligning div
								Dom.style
									display: 'inline-block'
									padding: '5px'
									boxSizing: 'border-box'
								items = 2
								while (Page.width()-32)/items > 180
									items++
								items--
								Dom.style width: 100/items+"%"
								Dom.div !-> # Bock div
									Dom.style
										backgroundColor: '#f2f2f2'
										padding: '5px'
										Box: 'horizontal'
										_borderRadius: '2px'
										border: '1px solid #e0e0e0'
									Dom.cls 'selectBlock'
									Dom.onTap
										cb: !->
											Modal.prompt tr("Amount paid for %1?", formatName(user.key())), (v) !->
												number = +v
												if not isNaN(number)
													log "number=", number, ", numberIsNaN=", number is NaN
													byO.set user.key(), number
												else
													Modal.show "Incorrect input: \""+v+"\", use a number for a fixed amount or a percentage."
												total = 0
												byO.iterate (user) !->
													total += user.peek()
												totalO.set total
												log "Amount updated=", byO
									Dom.style
										fontWeight: if amount then 'bold' else ''
									Ui.avatar Plugin.userAvatar(user.key()), style: marginRight: "10px"
									Dom.div !->
										Dom.style
											Flex: true
										Dom.div !->
											Dom.style 
												Flex: true
												overflow: 'hidden'
												textOverflow: 'ellipsis'
												whiteSpace: 'nowrap'
												marginTop: '10px'
											if amount
												Dom.style marginTop: "0"
											Dom.text formatName(user.key(), true)
										if amount
											Dom.div !->
												Dom.style Box: 'horizontal'
												Dom.div !->
													Dom.style Flex: true
													Dom.text formatMoney(number)
												Dom.div !->
													Icon.render
														data: 'good2'
														size: 20
														color: '#080'
	
		Obs.observe !->
			if not multiplePaidBy.get() and Plugin.users.count().get() > 1
				Dom.div !->
					Dom.style
						textAlign: 'center'
						color: Plugin.colors().highlight
						fontSize: "80%"
						padding: "5px"
						margin: "0 0 -8px 0"
					Dom.text "Add multiple users"
					Dom.onTap !->
						multiplePaidBy.set(true)

	Ui.list !->
		Dom.h2 tr("Paid for")
		log 'full list refresh'
		remainder = Obs.create(totalO.peek())
		Obs.observe !->
			remainder.set(totalO.get())
		forO = Obs.create {}
		if Db.shared.peek("transactions", editId)
			Db.shared.iterate "transactions", editId, "for", (user) !->
				forO.set user.key(), user.get()
		usersLeft = Obs.create(forO.count().peek())

		if edit
			forO.set edit.get('for')
		[handleChange] = Form.makeInput
			name: 'for'
			value: forO.peek()
		Obs.observe !->
			handleChange forO.get()
		Obs.observe !->
			users = Plugin.users.count().get()
			selected = forO.count().get()
			usersLeft.get()
			Dom.div !->
				Dom.text "Select all" if selected < users
				Dom.text "Deselect all" if selected is users
				Dom.style
					float: 'right'
					margin: '-34px -8px -20px 0'
					padding: '14px 8px 2px 8px'
					color: Plugin.colors().highlight
					fontSize: '80%'
				Dom.onTap !->
					if selected < users
						log "Select all"
						Plugin.users.iterate (user) !->
							if forO.peek(user.key()) is undefined
								forO.set(user.key(), true)
								usersLeft.modify((v) -> v+1)
					else
						log "Deselect all"
						forO = Obs.create {}
						usersLeft.set 0
		Obs.observe !->
			log "users refresh"
			Dom.div !->
				Dom.style margin: '5px -5px 0 -5px'
				Plugin.users.iterate (user) !->
					amount = forO.get(user.key())
					if amount is true
						usersLeft.get()
					number = 0
					suffix = undefined
					totalO.get()
					if amount
						if amount is true
							number = Math.round((remainder.get()*100.0)/usersLeft.get())/100.0
						else if (amount+"").substr(-1) is "%"
							amount = amount+""
							percent = +(amount.substr(0, amount.length-1))
							number = Math.round(percent*totalO.get())/100.0
							remainder.modify((v) -> v-number)
							suffix = percent+"%"
							usersLeft.modify (v) -> v-1
							Obs.onClean !->
								usersLeft.incr()
								remainder.modify((v) -> v+number)
						else
							number = +amount
							remainder.modify((v) -> v-number)
							suffix = "fixed"
							usersLeft.modify (v) -> v-1
							Obs.onClean !->
								usersLeft.incr()
								remainder.modify((v) -> v+number)
							
					# TODO: Assign possibly remaining part of the total to someone (only for show, server handles balances correctly)
					Dom.div !-> # Aligning div
						Dom.style
							display: 'inline-block'
							padding: '5px'
							boxSizing: 'border-box'
						items = 2
						while (Page.width()-32)/items > 180
							items++
						items--
						Dom.style width: 100/items+"%"
						Dom.div !-> # Bock div
							Dom.style
								backgroundColor: '#f2f2f2'
								padding: '5px'
								Box: 'horizontal'
								_borderRadius: '2px'
								border: '1px solid #e0e0e0'
							Dom.cls 'selectBlock'
							Dom.onTap
								cb: !->
									if amount?
										forO.set(user.key(), null)
										usersLeft.modify (v) -> v-1
									else
										forO.set(user.key(), true)
										usersLeft.incr()
									log "Clicked=", forO, ", usersLeft="+usersLeft.peek(), ", amount="+amount			
								longTap: !->
									Modal.prompt tr("Amount paid for %1?", formatName(user.key())), (v) !->
										number = +v
										if (v+"").substr(-1) is "%"
											log "modal percent received"
											percent = +((v+"").substr(0, v.length-1))
											if percent < 0 or percent >100
												Modal.show "Use a percentage between 0 and 100 instead of "+v+"."
												return
											else
												forO.set user.key(), v
												if not (amount?)
													usersLeft.incr()
										else if not isNaN(number)
											log "number=", number, ", numberIsNaN=", number is NaN
											forO.set user.key(), number
											if not (amount?)
												usersLeft.incr()
										else
											Modal.show "Incorrect input: \""+v+"\", use a number for a fixed amount or a percentage."
										log "Amount updated=", forO
							Dom.style
								fontWeight: if amount then 'bold' else ''
								clear: 'both'
							Ui.avatar Plugin.userAvatar(user.key()), style: marginRight: "10px"
							Dom.div !->
								Dom.style
									Flex: true
								Dom.div !->
									Dom.style 
										Flex: true
										overflow: 'hidden'
										textOverflow: 'ellipsis'
										whiteSpace: 'nowrap'
										marginTop: '10px'
									if amount
										Dom.style marginTop: "0"
									Dom.text formatName(user.key(), true)
								if amount
									Dom.div !->
										Dom.style Box: 'horizontal'
										Dom.div !->
											Dom.style Flex: true
											Dom.text formatMoney(number)
											if suffix isnt undefined
												Dom.div !->
													Dom.style 
														display: 'inline-block'
														margin: '0 0 0 3px'
														fontWeight: 'normal'
														fontSize: '90%'
													Dom.text " ("+suffix+")"
										Dom.div !->
											Icon.render
												data: 'good2'
												size: 20
												color: '#080'
										 
		Form.condition (values) ->
			remainderLocal = Obs.create totalO.peek()
			good = false
			forO.iterate (user) !->
				amount = user.peek()
				if (amount+"") is "true"
					good = true
					return
				else if (amount+"").substr(-1) is "%"
					amount = amount+""
					percent = +(amount.substr(0, amount.length-1))
					number = Math.round(percent*totalO.peek())/100.0
					remainderLocal.modify((v) -> v-number)
					Obs.onClean !->
						remainderLocal.modify((v) -> v+number)
				else
					number = +amount
					remainderLocal.modify((v) -> v-number)
					Obs.onClean !->
						remainderLocal.modify((v) -> v+number)
			if remainderLocal.peek() < 0 or (remainderLocal.peek() != 0 and not good)
				return tr("The totals do not match.")
	Dom.div !->
		Dom.style
			textAlign: 'center'
			fontStyle: 'italic'
			padding: '3px'
			color: '#aaa'
			fontSize: '85%'
		Dom.text tr("Hint: long-tap on a user to set a specific amount or percentage")

	if Db.shared.peek("transactions", editId)?
		Page.setActions
			icon: 'trash'
			label: "Remove transaction"
			action: !->
				Modal.confirm "Remove transaction",
					"Are you sure you want to remove this transaction?",
					!->
						log "Confirmed"
						Server.call 'removeTransaction', editId
						# Back to the main page
						Page.back()
						Page.back()

	Form.setPageSubmit (values) !->
		Page.up()
		total = 0
		byO.iterate (user) !->
			total += user.peek()
		values['total'] = total
		Server.call 'transaction', editId, values

# Sort static on top, then percentage, then remainder, then undefined
getSortValue = (key) ->
	if (key+"").substr(-1) is "%"
		return 0
	else if (key+"") is "true"
		return 1
	else if (key is undefined or not (key?))
		return 10
	else
		return -1
	
renderSettlePane = (settleO) !->		
	Ui.list !->
		Dom.h2 "Settle transactions"
		Dom.div !->
			Dom.style
				Flex: true
				margin: '4px 0'
				background: '#888'
				color: '#fff'
				fontSize: '80%'
				padding: '4px'
				fontStyle: 'italic'
				
			if account = Db.shared.get('accounts', Plugin.userId())
				Dom.text tr("Your account number: %1", account)
			else	
				Dom.text tr("Tap to setup your account number.")
			Dom.onTap !->
				Modal.prompt tr("Your account number"), (text) !->
					Server.sync 'account', text, !->
						Db.shared.set 'account', Plugin.userId(), text
								
		settleO.iterate (tx) !->
			Ui.item !->
				[from,to] = tx.key().split(':')
				done = tx.get('done')
				amount = tx.get('amount')
				Icon.render
					data: 'good2'
					color: if done&2 then '#080' else if done&1 then '#777' else '#ccc'
					style: {marginRight: '6px'}
				Dom.div !->
					if done&2
						Dom.text tr("%1 received %2 from %3", formatName(to,true), formatMoney(amount), formatName(from))
					else
						if done&1
							Dom.text tr("%1 paid %2 to %3", formatName(from,true), formatMoney(amount), formatName(to))
						else
							Dom.span !->
								Dom.style
									fontWeight: if +from is Plugin.userId() then 'bold' else ''
								Dom.text tr("%1 should pay %2 to %3", formatName(from,true), formatMoney(amount), formatName(to))
					
						Dom.div !->
							Dom.style
								fontSize: '80%'
								fontWeight: if +to is Plugin.userId() then 'bold' else ''
								
							if +to is Plugin.userId()
								Dom.text tr("Tap to confirm receipt of payment")
							else if done&1
								Dom.text tr("Waiting for %1 to confirm payment", formatName(to))
							else if account = Db.shared.get('accounts', to)
								Dom.text tr("Account: %1", account)
							else
								Dom.text tr("%1 has not entered account info", formatName(to))
							
				if +from is Plugin.userId() and !(done&2)
					Dom.onTap !->
						Server.sync 'settlePayed', tx.key(), !->
							tx.set 'done', (done&~1) | ((done^1)&1)
					
				else if +to is Plugin.userId()
					Dom.onTap !->
						Server.sync 'settleDone', tx.key(), !->
							tx.set 'done', (done&~2) | ((done^2)&2)

		if Plugin.userIsAdmin()
			Dom.div !->
				Dom.style textAlign: 'right'
				complete = true
				for k,v of settleO.get()
					if !(v.done&2)
						complete = false
						break
			
				buttonText = if complete then tr("Finish") else tr("Cancel")
				if complete
					Ui.button tr("Finish"), !->
						require('modal').confirm tr("Finish settle?"), tr("The pane will be discarded for all members."), !->
							Server.call 'settleStop'
				else
					Ui.button tr("Cancel"), !->
						require('modal').confirm tr("Cancel settle?"), tr("There are uncompleted settling transactions! When someone has paid without acknowledge of the recipient, balances might be inaccurate..."), !->
							Server.call 'settleStop'


formatMoney = (amount) ->
	number = amount.toFixed(2)
	currency = "€"
	if Db.shared.get("currency")
		currency = Db.shared.get("currency")
	return currency+number
	
formatName = (userId, capitalize) ->
	if +userId != Plugin.userId()
		Plugin.userName(userId)
	else if capitalize
		tr("You")
	else
		tr("you")
		
formatGroup = (userIds, capitalize) ->
	if userIds.length > 3
		userIds[0...3].map(formatName).join(', ') + ' and ' + (userIds.length-3) + ' others'
	else if userIds.length > 1
		userIds[0...userIds.length-1].map(formatName).join(', ') + ' and ' + Plugin.userName(userIds[userIds.length-1])
	else if userIds.length is 1
		formatName(userIds[0], capitalize)

selectUser = (cb) !->
	require('modal').show tr("Select user"), !->
	    Dom.style width: '80%'
	    Dom.div !->
	        Dom.style
	            maxHeight: '40%'
	            backgroundColor: '#eee'
	            margin: '-12px'
	        Dom.overflow()
	        Plugin.users.iterate (user) !->
	            Ui.item !->
	                Ui.avatar user.get('avatar')
	                Dom.text user.get('name')
	                Dom.onTap !->
	                    cb user.key()
	                    Modal.remove()
	        , (user) ->
	            +user.key()
	, false, ['cancel', tr("Cancel")]


exports.renderSettings = !->
	Dom.text "Select the currency symbol you want to use:"
	Dom.br()
	currencyInput = null
	Dom.div !->
		Dom.style display: 'inline-block', marginRight: "15px", width: "25px"
		text = '€'
		if Db.shared
			if Db.shared.get("currency")
				text = Db.shared.get("currency")
		currencyInput = Form.input
			name: 'currency'
			text: text
	log "currencyInput: ", currencyInput
	renderCurrency = (value) !->
		Ui.button !->
			Dom.text value
			Dom.style
				width: "20px"
				fontSize: "125%"
				textAlign: "center"
				padding: "4px 6px"
		, !->
			currencyInput.value(value)
	renderCurrency("€")
	renderCurrency("$")
	renderCurrency("£")


calculateShare = (transaction, id) ->
	calculatePart = (section, total, id) ->
		result = 0	
		remainder = Obs.create(total)
		usersLeft = Obs.create(section.count().get())
		Obs.observe !->
			section.iterate (user) !->
				amount = section.get(user.key())
				number = 0
				if amount
					if amount is true
						number = Math.round((remainder.get()*100.0)/usersLeft.get())/100.0
					else if (amount+"").substr(-1) is "%"
						amount = amount+""
						percent = +(amount.substr(0, amount.length-1))
						number = Math.round(percent*total.get())/100.0
						remainder.modify((v) -> v-number)
						usersLeft.modify (v) -> v-1
						Obs.onClean !->
							usersLeft.incr()
							remainder.modify((v) -> v+number)
					else
						number = +amount
						remainder.modify (v) -> v-number
						usersLeft.modify (v) -> v-1
						Obs.onClean !->
							usersLeft.incr()
							remainder.modify((v) -> v+number)
				if (user.key()+"") is (id+"")
					log "found user in share"
					result = number
		return result

	byAmount = calculatePart(transaction.ref('by'), transaction.get('total'), id)
	forAmount = calculatePart(transaction.ref('for'), transaction.get('total'), id)
	result = byAmount - forAmount
	log "byAmount="+byAmount+", forAmount="+forAmount+", result="+result
	return result

stylePositiveNegative = (amount) !->
	if amount > 0
	 	Dom.style color: "#080"
	else if amount < 0
	 	Dom.style color: "#E41B1B"

capitalizeFirst = (string) ->
	return string.charAt(0).toUpperCase() + string.slice(1)
		
Dom.css
	'.selected:not(.tap)':
		background: '#f0f0f0'
	'.selectBlock:hover':
		background: '#e0e0e0 !important'
		border: '1px solid #d0d0d0 !important'