-- /////////////////////////////////////////////////////////////////////////////////////////////////
-- // Name:        pprocess.lua
-- // Purpose:     Parallel Process class (Multithread) for Lide SDK
-- // Author:      Dario Cano [thdkano@gmail.com]
-- // Created:     2016/03/25
-- // Copyright:   (c) 2016 Dario Cano
-- // License:     lide license
-- /////////////////////////////////////////////////////////////////////////////////////////////////
---
--- Esta libreria require LuaLanes para su funcionamiento: 
--
---		Lanes.ABOUT : [  https://cmr.github.io/Lanes/#description ]
---
---			description	Running multiple Lua states in parallel
---			copyright	Copyright (c) 2007-10, Asko Kauppi; (c) 2011-13, Benoit Germain
---			author	Asko Kauppi <akauppi@gmail.com>, Benoit Germain <bnt.germain@gmail.com>
---			version	3.10.0
---			license	MIT/X11
---
---
--- >> Class constructor:
---
---  	object PProcess:new ( function fHandler ) 
---
---  	Arguments:
---
---		fHandler  			The function to execute in parallel proccess
---
---
--- >> Class methods:
---
--- 	obj *Timer 	getTimer()			Gets the timer associated as PReader (Process reader)
---		nil  		send()	 			Send data to this LuaState to the Parallel Process
---		...	        receive()	 		Receive data to this LuaState
---		nil	        run() 				Run the process
---
---		Esta clase representa un proceso en paralelo que se puede ejecutar en el sistema, al iniciar el 
---		nuevo proceso se creara un LuaState diferente en el que se van a ejecutar nuestras instrucciones;
---		por ésto s imprescindible ¡¡ CARGAR LAS LIBRERIAS  NECESARIAS tambien DENTRO DE EL NUEVO PROCESO.
---  		Esto lo podemos hacer facilmente utilizando "require()" normalmente dentro de la ejecucion del 
---		Proceso.
---
---
---	>> Example:
--
---		backgroundProcess = PProcess: new ( function () 
---			local luasql = require 'luasql.sqlite3'		  --> It's the same.
--			send('value to print')
--	 	end )
---
---		backgroundProcess.onRunning:setHandler ( function () 
--- 			print( backgroundProcess:get() )
--- 		end)
---
---
--- >> License: MIT License/X11 license
---
---		Copyright (c) 2016 Dario Cano [thdkano@gmail.com]
---		
---		Permission is hereby granted, free of charge, to any person obtaining a copy
---		of this software and associated documentation files (the "Software"), to deal
---		in the Software without restriction, including without limitation the rights
---		to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
---		copies of the Software, and to permit persons to whom the Software is
---		furnished to do so, subject to the following conditions:
---		
---		The above copyright notice and this permission notice shall be included in
---		all copies or substantial portions of the Software.
---		
---		THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
---		IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
---		FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
---		AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
---		LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
---		OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
---		SOFTWARE.

--- Importamos las clases y librerias necesarias

local PProcess, Lanes

local Timer = lide.classes.timer 		--> Nos sirve para leer los valores desde el Proceso Main
local Event = lide.classes.event 		--> Nos sirve para implementar los eventos necesarios

--- Cargamos la libreria lanes y seteamos "demote_full_userdata = true" para que nos permita pasar
--- valores userdata

---  Testeado lanes version 3.10.0: 
---  Windows   [OK]
---  GNU/Linux [OK]

Lanes = require 'lanes' . configure {
	demote_full_userdata = true
}

-- Definimos las constantes:
local PPROC_ENDED = lide.core.base.newid()
local PPROC_INIT  = lide.core.base.newid()

-- Definimos la clase
PProcess = class 'PProcess'
	: global(false)

function PProcess:PProcess( fHandler )
	local linda    = Lanes.linda()							--> Cada nuevo proceso tiene un nuevo linda asociado.
	local proc_id  = lide.core.base.newid()					--> Este lo usamos para comunicarnos internamente entre procesos
	local proc_usr = lide.core.base.newid()					--> Este lo usamos para enviar valores con send y receive
	
	public {
		onRunning = 'event', onEnded = 'event'
	}

	private {
		Linda = linda,	   	     		 					--> Linda           : El objeto linda nos ayudara a pasar datos entre procesos
		LKey  = proc_id,				  					--> Linda Key       : La clave de sincronizacion es unica por proceso
		UKey  = proc_usr,
		FHandler  = fHandler,	  		 					--> FunctionHandler : La funcion que va a ejecutar el proceso
		CurrLane  = lide.core.base.voidf,					--> Current Lane    : Inicializamos el Lane real como una funcion vacia
		PReader   = Timer:new(proc_id, function ( ... ) 	--> Process Reader  : Creamos un timer que nos servirá para monitorear el estado del proceso

			-- Ejecutar el evento onRunning/lector del usuario	
			if self.onRunning:getHandler() ~= lide.core.base.voidf then
				self.onRunning:call()
			end

			-- Chequeamos si el proceso está finalizado:
			if linda:get(proc_id) == PPROC_ENDED then
				self.onEnded:call()

				-- limpiamos los valores
				linda:set(proc_usr, nil)
				linda:set(proc_id, nil)

				self:getTimer():stop() --'PProcess: OK'
			end
		end),
	}
	
	local globals_to_send = {
		PPROC_ID    = proc_id,
		PPROC_ENDED = PPROC_ENDED,
		
		sended = function ( ... )
			return linda:get(proc_usr)
		end,
		
		--- La función send va a estar declarada en los handlers de pprocess como palabra clave
		--- su uso es exclusivo para enviar mensajes desde el proceso en paralelo a main luastate
		send = function ( what, other_key )
			linda:set(other_key or proc_usr, what)
		end,

		-- imprimir un error desde el pprocess
		pperror = function ( msg )
			print( 'PProcess, Error:', msg ) -- Solo funciono con print
			linda:set(proc_id, PPROC_ENDED)
		end
	}

	self.CurrLane = Lanes.gen ("*",
		{ 
			globals = globals_to_send
		},
	function ( )
		local x, e = pcall(fHandler) --> En esta parte de la función el valor "fHandler" lo tomamos directamente de los argumentos del constructor.
		if not x then
			print('PProcess, Error:', e)
		else
			-- Cortamos la ejecucion
			linda:set(proc_id, PPROC_ENDED)
		end
	end)

	-- Registramos los eventos asociados a la clase
	self.onRunning = Event:new( 'PPROC_onRunning', self, lide.core.base.voidf )
	self.onEnded   = Event:new( 'PPROC_onEnded'  , self, lide.core.base.voidf )
end

function PProcess:receive (other_key)
	return self.Linda:get(other_key or self.UKey)
end

function PProcess:getTimer( ... )
	return self.PReader
end

function PProcess:set( value, other_key )
	self.Linda:set(other_key or self.UKey, value)
end

function PProcess:run ()
	--printf('%s', self.LKey)
	self.Linda:set(self.LKey, PPROC_INIT)
	local x, e = pcall(self.CurrLane)
	if not x then
		print('PProcess, Error:', e)
	else
		self.PReader:start( 33 / 2 )
	end
end


return PProcess