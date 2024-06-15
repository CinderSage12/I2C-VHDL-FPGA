library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity i2c_controller is
	port (
			clock : in STD_LOGIC;									-- Master clock
			reset : in STD_LOGIC;									-- Master reset
			trigger : in STD_LOGIC;									-- Continuar después de la pausa
			restart : in STD_LOGIC;									-- Genera un nuevo INICIO
			last_byte : in STD_LOGIC;								-- Este es el último byte para leer/escribir.
			address : in STD_LOGIC_VECTOR (6 downto 0);		-- Slave address
			read_write : in STD_LOGIC;								-- 0=write, 1=read
			write_data : in STD_LOGIC_VECTOR (7 downto 0);	-- datos para escribir
			read_data : out STD_LOGIC_VECTOR (7 downto 0);	-- Datos que hemos leído
			ack_error : out STD_LOGIC;								-- 0=ACK, 1=NAK
			busy : out STD_LOGIC;									-- El controlador está procesando
			scl : inout STD_LOGIC;									-- Tri-state
			sda : inout STD_LOGIC);									-- Tri-state
end entity;

architecture behavioral of i2c_controller is
	type T_STATE is (START1, START2,
		WRITING_DATA, WRITING_ACK, WRITE_WAITING,
		READING_DATA, READING_ACK, READ_WAITING,
		STOP1, STOP2, STOP3,
		RESTART1
	);
	signal running : STD_LOGIC := '0';				-- No inactivo; trigger recibido
	signal pause_running : STD_LOGIC := '0';		-- Usado para esperar el siguinte trigger
	signal running_clock : STD_LOGIC;				-- Generator de 100KHz SCL
	signal previous_running_clock : STD_LOGIC;	-- Se usa para encontrar el edge
	signal state : T_STATE := START1;				-- Estado actual
	signal scl_local : STD_LOGIC := '1';			-- Copia local del output
	signal sda_local : STD_LOGIC := '1';			-- Copia local del output

begin
	process (reset, clock)
		variable i2c_clock_counter : UNSIGNED (6 downto 0);	-- Baja velocidad de SCL del clock principal
	begin
		if (reset = '1') then
			i2c_clock_counter := (others => '0');
			running <= '0';
		elsif (clock'Event and clock = '1') then
			if (trigger = '1') then
				-- Con un trigger, entra en running state y limpia el counter
				running <= '1';
				i2c_clock_counter := (others => '0');
			end if;
			if (running = '1') then
				-- Si esta en running, inicia el counter y extrae el MSB para el 2do process
				i2c_clock_counter := i2c_clock_counter + 1;
				previous_running_clock <= running_clock;
				running_clock <= i2c_clock_counter (6);
			end if;
			if (pause_running = '1') then
				-- Espera el 2do process como para escribir el sgte byte
				running <= '0';
			end if;
		end if;
	end process;

	process (reset, clock)
		variable clock_flip : STD_LOGIC := '0';						-- Para alternar el scl_local
		variable bit_counter : INTEGER range 0 to 8 := 0;			-- Se usa en read/write para contar bits bits
		variable data_to_write : STD_LOGIC_VECTOR (7 downto 0);	-- Datos a escribir o puede ser el slave
	begin
		if (reset = '1') then
			-- Tri-state en out y resetea para el sgte trigger
			scl_local <= '1';
			sda_local <= '1';
			state <= START1;
		elsif (clock'Event and clock = '1') then
			-- Por si no esta pausado
			pause_running <= '0';

			if (restart = '1') then
				-- Al restart fuerza el estado
				state <= RESTART1;
			end if;

			if (running = '1' and running_clock = '1' and previous_running_clock = '0') then
				case state is
					when START1 =>
						scl_local <= '1';
						sda_local <= '1';
						state <= START2;

					when START2 =>
						-- Prepárese para enviar la dirección configurando el recuento de bits y configurando
						-- el valor de byte que estamos escribiendo en la dirección + modo de lectura/escritura.
						sda_local <= '0';
						clock_flip := '0';
						bit_counter := 8;
						data_to_write := address & read_write;
						state <= WRITING_DATA;

					when WRITING_DATA =>
						-- Dos ciclos por bit
						scl_local <= clock_flip;
						-- Asigna el bit actual usando bit_counter
						sda_local <= data_to_write (bit_counter - 1);
						if (clock_flip = '1') then
							-- Cuando se envia todos los bits va a ACK
							bit_counter := bit_counter - 1;
							if (bit_counter = 0) then
								state <= WRITING_ACK;
							end if;
						end if;
						clock_flip := not clock_flip;

					when WRITING_ACK =>
						scl_local <= clock_flip;
						-- Tri-state el sda se va usar como input
						sda_local <= '1';
						if (clock_flip = '1') then
							-- Bloquea el input SDA
							ack_error <= sda;
							if (last_byte = '1') then
								-- Si es el ultimo bit se genera un STOP
								state <= STOP1;
							else
								-- Se espera al sgte trigger
								pause_running <= '1';
								if (read_write = '0') then
									state <= WRITE_WAITING;
								else
									state <= READ_WAITING;
								end if;
							end if;
						end if;
						clock_flip := not clock_flip;

					when WRITE_WAITING =>
						-- Se prepara para el sgte byte a escribir
						data_to_write := write_data;
						bit_counter := 8;
						state <= WRITING_DATA;

					when READING_DATA =>
						scl_local <= clock_flip;
						-- Tri-state el SDA para usar de input
						sda_local <= '1';
						if (clock_flip = '1') then
							-- Cuando termina de contar alterna a lectura
							-- ACK state
							bit_counter := bit_counter - 1;
							if (bit_counter = 0) then
								state <= READING_ACK;
							end if;
							-- Se lee el bit
							read_data (bit_counter) <= sda;
						end if;
						clock_flip := not clock_flip;

					when READING_ACK =>
						scl_local <= clock_flip;
						-- Se controla el ultimo byte
						sda_local <= last_byte;
						if (clock_flip = '1') then
							-- Si es el ultimo byte entra en STOP
							if (last_byte = '1') then
								state <= STOP1;
							else
								pause_running <= '1';
								state <= READ_WAITING;
							end if;
						end if;
						clock_flip := not clock_flip;

					when READ_WAITING =>
						-- Iniciliza el contador
						bit_counter := 8;
						state <= READING_DATA;

					when STOP1 =>
						sda_local <= '0';
						scl_local <= '0';
						state <= STOP2;

					when STOP2 =>
						scl_local <= '1';
						state <= STOP3;

					when STOP3 =>
						-- Espera al sgte trigger para volver a empezar la secuencia
						sda_local <= '1';
						pause_running <= '1';
						state <= START1;

					when RESTART1 =>
						-- Resetea las lineas para volver a empezar
						scl_local <= '0';
						sda_local <= '0';
						state <= START1;
				end case;
			end if;
		end if;
	end process;

	busy <= running;
	-- Tri-state si la señal es 1
	scl <= 'Z' when (scl_local = '1') else '0';
	sda <= 'Z' when (sda_local = '1') else '0';
end architecture;
