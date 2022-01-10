def get_env_variable(key)
    return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

def set_env_variables(keys,value)
    open(ENV['AC_ENV_FILE_PATH'], 'a') { |f|
        keys.each_with_index do |key,index|
            f.puts "#{key}=#{value}"
        end
    }
end

env_keys = get_env_variable("AC_ENV_KEYS") || abort('Missing Environtment Variable Keys')
env_value = get_env_variable("AC_ENV_VALUE") || ''
keys_array = env_keys.split(" ")
set_env_variables(keys_array,env_value)